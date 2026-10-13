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
#       .dockerignore

rspec_environment_dir = ".saturnci/environments/rspec"

empty_directory ".saturnci/workflows"
empty_directory ".saturnci/jobs/test_suite"
empty_directory rspec_environment_dir

# The test suite job. It declares which environment it runs in, and which
# service in that environment runs the tests.
create_file ".saturnci/jobs/test_suite/config.yml", <<~CONFIG
  environment: rspec
  service: saturnci_test_app
CONFIG

# Dockerfile for the rspec environment
create_file "#{rspec_environment_dir}/Dockerfile", <<~DOCKERFILE
  # SaturnCI Test Environment Docker Image
  #
  # This Dockerfile creates the container image that SaturnCI uses to run
  # your tests. It holds Ruby, system packages, and gems. The app's code is mounted
  # in at run time, and SaturnCI precompiles assets then.

  # SaturnCI passes your app's .ruby-version in as SATURNCI_RUBY_VERSION.
  ARG SATURNCI_RUBY_VERSION
  FROM ruby:\${SATURNCI_RUBY_VERSION}-slim

  WORKDIR /app

  RUN apt-get update && apt-get install -y \\
      build-essential \\
      libpq-dev \\
      nodejs \\
      git \\
      libyaml-dev \\
      && rm -rf /var/lib/apt/lists/*

  COPY Gemfile Gemfile.lock ./
  RUN bundle install && rm -rf /usr/local/bundle/cache/*
DOCKERFILE

# docker-compose.yml for the rspec environment
create_file "#{rspec_environment_dir}/docker-compose.yml", <<~DOCKERCOMPOSE
  # SaturnCI Docker Environment
  #
  # This Docker Compose file specifies the environment that SaturnCI uses to run
  # your tests.

  services:
    saturnci_test_app:
      # This hostname is what will go in the Capybara host config.
      hostname: saturnci_test_app

      image: \${SATURN_TEST_APP_IMAGE_URL}
      build:
        context: ../../..
        dockerfile: #{rspec_environment_dir}/Dockerfile
      volumes:
        - ../../../:/app
      depends_on:
        - postgres
        - chrome

      # .env is where SaturnCI will put the environment variables that you set
      # in your repository's Secrets section in Settings.
      env_file:
        - .env

      environment:
        SATURNCI_ENV: "true"
        # No database name in the URL, so Rails keeps the one from your own
        # config/database.yml and takes only the connection details from here.
        DATABASE_URL: postgres://postgres@postgres:5432
        SATURNCI_CHROME_URL: http://chrome:4444/
        RAILS_ENV: test

    postgres:
      image: postgres:17.2-alpine
      environment:
        POSTGRES_HOST_AUTH_METHOD: trust

    chrome:
      image: selenium/standalone-chromium
      shm_size: 2g
DOCKERCOMPOSE

# .dockerignore for the environment
create_file "#{rspec_environment_dir}/.dockerignore", <<~DOCKERIGNORE
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

      Capybara::Selenium::Driver.new(app, browser: :remote, url: ENV.fetch("SATURNCI_CHROME_URL"), options: options)
    end

    Capybara.server_host = "0.0.0.0"
    Capybara.app_host = "http://\#{Socket.gethostname}"
    Capybara.always_include_port = true

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
say "1. Add this repository to SaturnCI at https://app.saturnci.com"
say "2. Commit these changes and push. SaturnCI runs your tests on every push."
