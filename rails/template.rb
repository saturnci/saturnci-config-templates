# SaturnCI Rails Application Template
# This template adds SaturnCI configuration to an existing Rails application
#
# Usage: rails app:template LOCATION=path/to/saturnci_template.rb

say "Adding SaturnCI configuration to your Rails application..."

# SaturnCI uses a config-based layout:
#
#   .saturnci/
#     workflows/default_workflow.rb       <- what runs on every push
#     jobs/test_suite/config.yml          <- the test suite job, points at an environment
#     environments/rspec/                 <- the reusable environment the job runs in
#       Dockerfile
#       docker-compose.yml
#       .env
#       .dockerignore

empty_directory ".saturnci/workflows"
empty_directory ".saturnci/jobs/test_suite"
empty_directory ".saturnci/environments/rspec"

# The test suite job. It declares which environment it runs in, and which
# service in that environment runs the tests.
create_file ".saturnci/jobs/test_suite/config.yml", <<~CONFIG
  environment: rspec
  service: saturnci_test_app
CONFIG

# Dockerfile for the rspec environment
create_file ".saturnci/environments/rspec/Dockerfile", <<~DOCKERFILE
  # SaturnCI Test Environment Docker Image
  #
  # This Dockerfile creates the container image that SaturnCI uses to run
  # your tests. It includes all necessary dependencies for a Rails application with
  # PostgreSQL and handles asset precompilation during the build process.
  #
  # This image is used by the environment's docker-compose.yml to create the test
  # execution environment.

  # Use ruby:4.0.1-slim as the base image. This provides a pre-built Linux
  # environment with Ruby already installed. The "slim" version contains only
  # essential packages, making it smaller and faster to download.
  FROM ruby:4.0.1-slim

  # Set /app as the working directory. All subsequent commands will run from here.
  WORKDIR /app

  ENV RAILS_ENV=test

  # Update the package list to get the latest available packages.
  RUN apt-get update && apt-get install -y \\

      # Install compilers and build tools needed for native gem compilation.
      build-essential \\

      # Install PostgreSQL client libraries for database connections.
      libpq-dev \\

      # Install JavaScript runtime for asset processing.
      nodejs \\

      # Install version control system for dependency management.
      git \\

      # Install libyaml headers required to build the psych gem on Ruby 3.2+.
      libyaml-dev \\

      # Clean up package cache to reduce image size.
      && rm -rf /var/lib/apt/lists/*

  COPY Gemfile Gemfile.lock ./
  RUN bundle install && rm -rf /usr/local/bundle/cache/*

  # Copy all application files. Use .dockerignore to exclude unnecessary files.
  COPY . ./

  # Dummy database environment variables required for asset precompilation.
  # Rails loads the application environment during asset compilation, which
  # evaluates database.yml and may trigger database connections in initializers.
  # These dummy values prevent build failures when no database is available.
  ENV DATABASE_NAME=dummy_database_name
  ENV DATABASE_USERNAME=dummy_database_username
  ENV DATABASE_PASSWORD=dummy_database_password
  ENV DATABASE_HOST=localhost
  ENV DATABASE_PORT=5432

  RUN bundle exec rails assets:precompile && \\
      rm -rf tmp/cache node_modules/.cache

  CMD ["bundle", "exec", "rails", "server", "-b", "0.0.0.0"]
DOCKERFILE

# docker-compose.yml for the rspec environment
create_file ".saturnci/environments/rspec/docker-compose.yml", <<~DOCKERCOMPOSE
  # SaturnCI Docker Environment
  #
  # This Docker Compose file specifies the environment that SaturnCI uses to run
  # your tests.
  #
  # Local Development Usage:
  #   cd .saturnci/environments/rspec
  #
  #   Start all services
  #   docker-compose up -d
  #
  #   Get shell in app container
  #   docker-compose run saturnci_test_app bash
  #
  #   Run tests
  #   docker-compose run saturnci_test_app bundle exec rspec
  #
  #   Stop and remove containers
  #   docker-compose down

  version: "3.8"

  services:
    saturnci_test_app:
      # This hostname is what will go in the Capybara host config.
      hostname: saturnci_test_app

      image: \${SATURN_TEST_APP_IMAGE_URL}
      build:
        context: ../../..
        dockerfile: .saturnci/environments/rspec/Dockerfile
      volumes:
        - ../../../:/app
      depends_on:
        - postgres
        - chrome

      # .env is where SaturnCI will put the environment variables that you set
      # in your repository's Secrets section in Settings.
      #
      # Optionally, you can add a local .saturnci.env file to provide environment
      # variables when you run your SaturnCI setup locally.
      env_file:
        - .env

      environment:
        SATURNCI_ENV: "true"
        # No database name in the URL, so Rails keeps the one from your own
        # config/database.yml and takes only the connection details from here.
        DATABASE_URL: postgres://saturn@postgres:5432
        RAILS_ENV: test

      healthcheck:
        test: ["CMD", "curl", "--fail", "http://localhost:3000"]
        interval: 10s
        timeout: 5s
        retries: 10

    postgres:
      image: postgres:17.2-alpine
      volumes:
        - postgresql:/var/lib/postgresql/data:delegated
      environment:
        PSQL_HISTFILE: /usr/src/app/log/.psql_history
        POSTGRES_USER: saturn
        POSTGRES_HOST_AUTH_METHOD: trust
      restart: on-failure
      healthcheck:
        test: ["CMD-SHELL", "pg_isready -U saturn"]
        interval: 10s
        timeout: 2s
        retries: 10
      logging:
        driver: none

    chrome:
      image: seleniarm/standalone-chromium
      hostname: chrome
      shm_size: 2g
      healthcheck:
        test: ["CMD", "curl", "--fail", "http://localhost:4444/wd/hub/status"]
        interval: 10s
        timeout: 5s
        retries: 5

  volumes:
    postgresql:
DOCKERCOMPOSE

# Basic .env file (without sensitive credentials)
create_file ".saturnci/environments/rspec/.env", <<~ENV
  DATABASE_USERNAME=saturn
  DATABASE_PASSWORD=""
  DATABASE_HOST=127.0.0.1
  DATABASE_PORT=5432

  SATURN_TEST_APP_IMAGE_URL=""
ENV

# .dockerignore for the environment
create_file ".saturnci/environments/rspec/.dockerignore", <<~DOCKERIGNORE
  # Version control
  .git
  .gitignore

  # Logs and temp files
  log
  tmp
  *.log

  # Dependency directories
  node_modules
  coverage

  # Environment and secrets
  .env*

  # Documentation
  *.md

  # System files
  .DS_Store
DOCKERIGNORE

# The workflow. SaturnCI runs .saturnci/workflows/default_workflow.rb on every
# push, so this file is required — without it the run fails immediately with
# "No such file or directory" and no test suite run is ever created.
create_file ".saturnci/workflows/default_workflow.rb", <<~WORKFLOW
  # SaturnCI runs this file on every push. It decides what jobs to run.
  #
  # This default version runs the test suite and finishes. As you add jobs under
  # .saturnci/jobs, start them here too.
  class DefaultWorkflow
    def initialize(env: ENV)
      @env = env
    end

    def perform(io: $stdout)
      test_suite_run = workflow_run.test_suite_runs.create(
        job_name: "test_suite",
        task_adapter_name: "rails_rspec",
        idempotent: true
      )

      test_suite_run.start

      io.puts "Started test_suite run: id=\#{test_suite_run.id} url=\#{test_suite_run.url}"

      # SaturnCI re-runs this workflow as jobs complete, so only finish once the
      # test suite has actually reported back. Finishing straight after start
      # would close the workflow while the suite was still running.
      workflow_run.finish if test_suite_run_finished?
    end

    private

    def test_suite_run_finished?
      run = workflow_run.job_runs.list(job_name: "test_suite").first
      return false unless run

      run.passed? || run.failed?
    end

    def workflow_run
      @workflow_run ||= SaturnCI::WorkflowRun.find(
        client: saturnci_client,
        id: @env.fetch("WORKFLOW_RUN_ID")
      )
    end

    def saturnci_client
      SaturnCI::Client.new(
        SaturnCI::Credentials.new(api_token: @env.fetch("SATURNCI_ACCESS_TOKEN"))
      )
    end
  end

  DefaultWorkflow.new.perform if $PROGRAM_NAME == __FILE__
WORKFLOW

# .gitignore for the .saturnci directory
create_file ".saturnci/.gitignore", <<~GITIGNORE
  environments/*/.env
GITIGNORE

# Add RSpec if not already present
gem_group :development, :test do
  gem "rspec-rails" unless File.read("Gemfile").include?("rspec-rails")
end

# Generate RSpec configuration if not present
generate "rspec:install" unless File.exist?("spec/spec_helper.rb")

# In SaturnCI, system specs drive the browser in the environment's chrome
# service, which reaches the app at the app container's hostname.
create_file "spec/support/saturnci_capybara.rb", <<~CAPYBARA
  if ENV["SATURNCI_ENV"].present?
    Capybara.register_driver :saturnci_chrome do |app|
      options = Selenium::WebDriver::Chrome::Options.new
      options.add_argument("--headless")
      options.add_argument("--no-sandbox")
      options.add_argument("--disable-dev-shm-usage")

      Capybara::Selenium::Driver.new(app, browser: :remote, url: "http://chrome:4444/", options: options)
    end

    Capybara.server_host = "0.0.0.0"
    Capybara.server_port = 3000
    Capybara.app_host = "http://\#{Socket.gethostname}:3000"

    RSpec.configure do |config|
      config.before(:each, type: :system) do
        driven_by :saturnci_chrome
      end
    end
  end
CAPYBARA

append_to_file "spec/rails_helper.rb", <<~RUBY

  require_relative "support/saturnci_capybara"
RUBY

say "SaturnCI configuration has been added to your Rails application!"
say ""
say "Next steps:"
say "1. Run 'bundle install' to install any new gems"
say "2. Navigate to the environment: cd .saturnci/environments/rspec"
say "3. Start the test environment: docker-compose up -d"
say "4. Run your tests: docker-compose run saturnci_test_app bundle exec rspec"
say "5. Stop the environment: docker-compose down"
say ""
say "You can now add this repository to SaturnCI at https://app.saturnci.com"
