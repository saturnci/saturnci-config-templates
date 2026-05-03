# SaturnCI Rails Application Template
# This template adds SaturnCI configuration to an existing Rails application
#
# Usage: rails app:template LOCATION=path/to/saturnci_template.rb

say "Adding SaturnCI configuration to your Rails application..."

# Create .saturnci directory
empty_directory ".saturnci"

# Create Dockerfile for SaturnCI test environment
create_file ".saturnci/Dockerfile", <<~DOCKERFILE
  # SaturnCI Test Environment Docker Image
  #
  # This Dockerfile creates the container image that SaturnCI uses to run
  # your tests. It includes all necessary dependencies for a Rails application with
  # PostgreSQL and handles asset precompilation during the build process.
  #
  # This image is used by .saturnci/docker-compose.yml to create the test execution environment.

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

# Create docker-compose.yml for SaturnCI
create_file ".saturnci/docker-compose.yml", <<~DOCKERCOMPOSE
  # SaturnCI Docker Environment
  #
  # This Docker Compose file specifies the environment that SaturnCI uses to run
  # your tests.
  #
  # Local Development Usage:
  #   cd .saturnci
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
        context: ..
        dockerfile: .saturnci/Dockerfile
      volumes:
        - ../:/app
        - ./database.yml:/app/config/database.yml:ro
      depends_on:
        - postgres
        - chrome

      # .saturnci/.env is where SaturnCI will put the environment variables
      # that you set in your repository's Secrets section in Settings.
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
      ports:
        - "127.0.0.1:5432:5432"
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
      ports:
        - "4444:4444"
      healthcheck:
        test: ["CMD", "curl", "--fail", "http://localhost:4444/wd/hub/status"]
        interval: 10s
        timeout: 5s
        retries: 5

  volumes:
    postgresql:
DOCKERCOMPOSE

# Create database.yml for test environment
create_file ".saturnci/database.yml", <<~DATABASE
  test:
    database: saturn_test
    adapter: postgresql
    encoding: unicode
    username: <%= ENV.fetch("DATABASE_USERNAME") %>
    host: <%= ENV.fetch("DATABASE_HOST") %>
    port: <%= ENV.fetch("DATABASE_PORT") %>
DATABASE

# Create convenience shell scripts
create_file ".saturnci/up.sh", <<~SCRIPT
  #!/bin/bash
  docker-compose -f .saturnci/docker-compose.yml up -d
SCRIPT

create_file ".saturnci/down.sh", <<~SCRIPT
  #!/bin/bash
  docker-compose -f .saturnci/docker-compose.yml down --remove-orphans
SCRIPT

create_file ".saturnci/run.sh", <<~SCRIPT
  #!/bin/bash
  docker-compose -f .saturnci/docker-compose.yml run saturn_test_app $@
SCRIPT

create_file ".saturnci/pre.sh", <<~SCRIPT
  #!/bin/bash
  bundle exec rails db:prepare
SCRIPT

# Detect the GitHub repository full name (e.g., "owner/repo") from git remote.
github_repo_full_name =
  begin
    remote_url = `git config --get remote.origin.url`.strip
    if (match = remote_url.match(%r{github\.com[:/]([^/]+/[^/.]+)(?:\.git)?$}))
      match[1]
    else
      "your-org/your-repo"
    end
  end

# Create entrypoint job that triggers a rails_rspec test suite run on every push.
empty_directory ".saturnci/jobs/entrypoint"

create_file ".saturnci/jobs/entrypoint/run", <<~RUN
  #!/usr/bin/env ruby

  def run(io, error_io, github_event, client)
    io.puts "SaturnCI SDK version: \#{SaturnCI::VERSION}"

    return 0 unless github_event == "push"
    return 0 if ENV['DELETED'] == "true"

    branch_name = ENV['BRANCH_NAME']
    if branch_name.to_s.empty?
      error_io.puts "BRANCH_NAME env var is required"
      return 1
    end

    commit_hash = ENV['COMMIT_HASH']
    if commit_hash.to_s.empty?
      error_io.puts "COMMIT_HASH env var is required"
      return 1
    end

    commit_message = ENV['COMMIT_MESSAGE']
    author_name = ENV['AUTHOR_NAME']

    io.puts "Branch name: \#{branch_name}"
    io.puts "Commit hash: \#{commit_hash}"
    io.puts "Commit message: \#{commit_message}"
    io.puts "Author name: \#{author_name}"

    test_suite_run = SaturnCI::TestSuiteRun.create(
      client: client,
      repository: '#{github_repo_full_name}',
      branch_name: branch_name,
      commit_hash: commit_hash,
      commit_message: commit_message,
      author_name: author_name,
      task_adapter_name: 'rails_rspec'
    )

    io.puts "Testing: \#{test_suite_run.url}"
    test_suite_run.wait_for_completion
    io.puts "Tests \#{test_suite_run.status.downcase}."

    0
  end

  def client
    SaturnCI::Client.new(credentials)
  end

  def credentials
    SaturnCI::Credentials.new(
      api_token: ENV.fetch('SATURNCI_ACCESS_TOKEN')
    )
  end

  exit run($stdout, $stderr, ENV['GITHUB_EVENT'], client) if $PROGRAM_NAME == __FILE__
RUN

create_file ".saturnci/jobs/entrypoint/Dockerfile", <<~DOCKERFILE
  FROM ruby:3.4-slim AS builder

  RUN apt-get update && apt-get install -y \\
    git \\
    && rm -rf /var/lib/apt/lists/*

  RUN git clone https://github.com/saturnci/saturnci-sdk.git /tmp/saturnci-sdk \\
    && cd /tmp/saturnci-sdk \\
    && gem build saturnci-sdk.gemspec

  FROM ruby:3.4-slim
  COPY --from=builder /tmp/saturnci-sdk/saturnci-sdk-*.gem /tmp/
  RUN gem install /tmp/saturnci-sdk-*.gem && rm /tmp/saturnci-sdk-*.gem

  ENTRYPOINT ["ruby", "-rsaturnci-sdk"]
DOCKERFILE

create_file ".saturnci/jobs/entrypoint/docker-compose.yml", <<~DOCKERCOMPOSE
  services:
    job:
      build:
        context: ../../..
        dockerfile: .saturnci/jobs/entrypoint/Dockerfile
      volumes:
        - ../../../:/app
      working_dir: /app
DOCKERCOMPOSE

# Make shell scripts executable
chmod ".saturnci/up.sh", 0755
chmod ".saturnci/down.sh", 0755
chmod ".saturnci/run.sh", 0755
chmod ".saturnci/pre.sh", 0755
chmod ".saturnci/jobs/entrypoint/run", 0755

# Create basic .env file (without sensitive credentials)
create_file ".saturnci/.env", <<~ENV
  DATABASE_USERNAME=saturn
  DATABASE_PASSWORD=""
  DATABASE_HOST=127.0.0.1
  DATABASE_PORT=5432

  SATURN_TEST_APP_IMAGE_URL=""
ENV

# Create .dockerignore for .saturnci directory
create_file ".saturnci/.dockerignore", <<~DOCKERIGNORE
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

# Create .gitignore for .saturnci directory
create_file ".saturnci/.gitignore", <<~GITIGNORE
  .env
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
say "2. Navigate to .saturnci directory: cd .saturnci"
say "3. Start the test environment: ./up.sh"
say "4. Run your tests: ./run.sh bundle exec rspec"
say "5. Stop the environment: ./down.sh"
say ""
say "You can now add this repository to SaturnCI at https://app.saturnci.com"