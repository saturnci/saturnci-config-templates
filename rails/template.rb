# SaturnCI Rails Application Template
# This template adds SaturnCI configuration to an existing Rails application
#
# Usage: rails app:template LOCATION=path/to/saturnci_template.rb

say "Adding SaturnCI configuration to your Rails application..."

# SaturnCI uses a config-based layout:
#
#   .saturnci/
#     jobs/clone_repo/                    <- the job that runs on every push
#     jobs/test_suite/config.yml          <- the test suite job, points at an environment
#     environments/rspec/                 <- the reusable environment the job runs in
#       Dockerfile
#       docker-compose.yml
#       database.yml
#       .env
#       .dockerignore
#     transitions/                        <- transitions decide what runs next

empty_directory ".saturnci/jobs/clone_repo"
empty_directory ".saturnci/jobs/github_push"
empty_directory ".saturnci/jobs/test_suite"
empty_directory ".saturnci/environments/rspec"
empty_directory ".saturnci/transitions"

# The clone_repo job runs when SaturnCI receives a push. It clones the
# repository into the pipeline workspace. It runs in the saturnci/transition
# environment, which SaturnCI provides.
create_file ".saturnci/jobs/clone_repo/config.yml", <<~CONFIG
  environment: saturnci/transition
CONFIG

create_file ".saturnci/jobs/clone_repo/clone_repo_job.rb", <<~RUBY
  class CloneRepoJob
    def initialize(io: $stdout)
      @io = io
    end

    def perform(job_run)
      if job_run.environment.file_exists?(job_run.pipeline_workspace_dir)
        @io.puts "Working copy of \#{job_run.repository.github_repo_full_name} " \\
                 "found at \#{job_run.pipeline_workspace_dir}"
      else
        @io.puts "Working copy of \#{job_run.repository.github_repo_full_name} not found in pipeline workspace, " \\
                 "cloning into \#{job_run.pipeline_workspace_dir}"
        job_run.environment.clone_repo
      end
    end
  end

  if $PROGRAM_NAME == __FILE__
    client = SaturnCI::Client.new(SaturnCI::Credentials.new(api_token: ENV.fetch('SATURNCI_ACCESS_TOKEN')))
    job_run = SaturnCI::JobRun.find(client: client, id: ENV.fetch('JOB_RUN_ID'))
    CloneRepoJob.new(io: $stdout).perform(job_run)
  end
RUBY

# The clone_repo job's transition decides what runs next -- here, it
# triggers the test suite.
create_file ".saturnci/transitions/clone_repo_transition.rb", <<~RUBY
  class CloneRepoTransition
    def after(_job_run)
      [
        {
          task_adapter_name: "rails_rspec",
          job_name: "test_suite",
          job_run_type: "test_suite_run"
        }
      ]
    end
  end
RUBY

# github_push is the legacy name for the clone_repo job. Repositories created
# before the rename run it; these files are kept during the migration.
create_file ".saturnci/jobs/github_push/config.yml", <<~CONFIG
  environment: saturnci/transition
CONFIG

create_file ".saturnci/jobs/github_push/github_push_job.rb", <<~RUBY
  class GitHubPushJob
    def initialize(io: $stdout)
      @io = io
    end

    def perform(job_run)
      if job_run.environment.file_exists?(job_run.pipeline_workspace_dir)
        @io.puts "Working copy of \#{job_run.repository.github_repo_full_name} " \\
                 "found at \#{job_run.pipeline_workspace_dir}"
      else
        @io.puts "Working copy of \#{job_run.repository.github_repo_full_name} not found in pipeline workspace, " \\
                 "cloning into \#{job_run.pipeline_workspace_dir}"
        job_run.environment.clone_repo
      end
    end
  end

  if $PROGRAM_NAME == __FILE__
    client = SaturnCI::Client.new(SaturnCI::Credentials.new(api_token: ENV.fetch('SATURNCI_ACCESS_TOKEN')))
    job_run = SaturnCI::JobRun.find(client: client, id: ENV.fetch('JOB_RUN_ID'))
    GitHubPushJob.new(io: $stdout).perform(job_run)
  end
RUBY

# The github_push job's transition decides what runs next -- here, it
# triggers the test suite.
create_file ".saturnci/transitions/github_push_transition.rb", <<~RUBY
  class GitHubPushTransition
    def after(_job_run)
      [
        {
          task_adapter_name: "rails_rspec",
          job_name: "test_suite",
          job_run_type: "test_suite_run"
        }
      ]
    end
  end
RUBY

# The test suite job. It declares which environment it runs in.
create_file ".saturnci/jobs/test_suite/config.yml", <<~CONFIG
  environment: rspec
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
  #   docker-compose run saturn_test_app bash
  #
  #   Run tests
  #   docker-compose run saturn_test_app bundle exec rspec
  #
  #   Stop and remove containers
  #   docker-compose down

  version: "3.8"

  services:
    saturn_test_app:
      # This hostname is what will go in the Capybara host config.
      hostname: saturn_test_app

      image: \${SATURN_TEST_APP_IMAGE_URL}
      build:
        context: ../../..
        dockerfile: .saturnci/environments/rspec/Dockerfile
      volumes:
        - ../../../:/app
        - ./database.yml:/app/config/database.yml:ro
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
        DOCKER_ENV: "true"
        DATABASE_USERNAME: saturn
        DATABASE_PASSWORD: ""
        DATABASE_HOST: postgres
        DATABASE_PORT: 5432
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

# database.yml for the test environment
create_file ".saturnci/environments/rspec/database.yml", <<~DATABASE
  test:
    database: saturn_test
    adapter: postgresql
    encoding: unicode
    username: <%= ENV.fetch("DATABASE_USERNAME") %>
    host: <%= ENV.fetch("DATABASE_HOST") %>
    port: <%= ENV.fetch("DATABASE_PORT") %>
DATABASE

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

say "SaturnCI configuration has been added to your Rails application!"
say ""
say "Next steps:"
say "1. Run 'bundle install' to install any new gems"
say "2. Navigate to the environment: cd .saturnci/environments/rspec"
say "3. Start the test environment: docker-compose up -d"
say "4. Run your tests: docker-compose run saturn_test_app bundle exec rspec"
say "5. Stop the environment: docker-compose down"
say ""
say "You can now add this repository to SaturnCI at https://app.saturnci.com"
