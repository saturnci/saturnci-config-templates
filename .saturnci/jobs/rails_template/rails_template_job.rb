# Verifies the public SaturnCI Rails config template: generate a fresh Rails app,
# apply the template to it, push it, and wait for the resulting test suite run.
#
# The artifact under test is rails/template.rb in this commit of this repo. The
# generated app and its run are only instruments for exercising it.
#
# This is a port of spec/e2e/create_test_app.rb, which was a standalone script
# with no assertions. The one thing added here is the wait at the end, so a
# broken template actually fails the job instead of passing silently.

require "json"
require "net/http"
require "tmpdir"
require "fileutils"
require "saturnci-sdk"

class RailsTemplateJob
  class GitHubConnectionError < StandardError; end

  # Long-lived fixture, provisioned in ops/github/terraform. The job force-pushes
  # main, so a reused repository is indistinguishable from a fresh one — and
  # creating one per run would need org Administration:write, which no
  # credential here carries.
  FIXTURE_REPO = "saturnci/rails-template-fixture"
  GITHUB_TOKEN_VAR = "GITHUB_RAILS_TEMPLATE_FIXTURE_TOKEN"
  APP_DIR = "rails-template-fixture"
  TEMPLATE_PATH = File.expand_path("../../../rails/template.rb", __dir__)

  # Both GitHub calls are safe to repeat: a read and a force push.
  GITHUB_MAX_RETRY_COUNT = 2
  GITHUB_RETRY_INTERVAL_SECONDS = 15
  GITHUB_CONNECTION_ERRORS = [
    Net::OpenTimeout,
    Net::ReadTimeout,
    SocketError,
    Errno::ECONNRESET,
    Errno::ECONNREFUSED,
    GitHubConnectionError
  ].freeze

  # The fixture's own workflow has to be queued, dispatched, and run before it
  # creates a test suite run, which takes a couple of minutes on a busy cluster.
  # Bounded so a fixture that is not wired up to SaturnCI fails the job instead
  # of holding a runner forever.
  RUN_APPEARANCE_TIMEOUT_SECONDS = 900
  POLL_INTERVAL_SECONDS = 15

  # Compared case- and space-insensitively: the API has returned both "passed"
  # and "Timed Out" shapes, and the SDK pinned here carries a stale list.
  TERMINAL_STATUSES = %w[passed failed cancelled timed_out].freeze
  PASSED_STATUS = "passed"

  def initialize(io: $stdout, error_io: $stderr, env: ENV)
    @io = io
    @error_io = error_io
    @env = env
  end

  def perform
    verify_github_token
    start_postgres
    configure_git

    commit_hash = nil

    Dir.mktmpdir("rails-app") do |temp_dir|
      Dir.chdir(temp_dir) do
        @io.puts "Generating Rails app in #{temp_dir}"
        run!("rails new #{APP_DIR} --database=postgresql --skip-test")

        Dir.chdir(APP_DIR) do
          add_rspec
          add_model_and_schema
          add_passing_spec
          add_system_spec
          commit_app
          apply_template
          commit_hash = commit_template
          push
        end
      end
    end

    wait_for_test_suite_run(commit_hash)
  end

  private

  # `rails new --database=postgresql` runs db:migrate, so a server has to be
  # listening before anything else happens.
  def start_postgres
    @io.puts "Starting Postgres..."
    run!("service postgresql start")
    run!(%(su postgres -c "psql -c \\"CREATE ROLE root SUPERUSER LOGIN\\"" ))
    @io.puts "Postgres ready."
  end

  # Fail with the actual reason rather than letting a dead credential surface as
  # an opaque push failure several minutes into the run.
  def verify_github_token
    uri = URI("https://api.github.com/repos/#{FIXTURE_REPO}")
    request = Net::HTTP::Get.new(uri)
    request["Authorization"] = "Bearer #{github_token}"
    request["Accept"] = "application/vnd.github+json"
    response = with_github_retries do
      Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(request) }
    end

    return if response.code == "200"

    raise "GitHub rejected #{GITHUB_TOKEN_VAR} with HTTP #{response.code} for #{FIXTURE_REPO}. " \
          "The token is expired, revoked, or not scoped to that repository; mint a new one " \
          "with Contents: Read and write and update the repository secret."
  end

  def configure_git
    run!("git config --global user.email saturnci.automations@gmail.com")
    run!("git config --global user.name saturnci-test")
  end

  def add_rspec
    @io.puts "Setting up RSpec..."
    gemfile = File.read("Gemfile")
    gemfile = gemfile.gsub(
      /(group :development, :test do\n)/,
      "\\1  gem \"rspec-rails\"\n"
    )
    File.write("Gemfile", gemfile)

    run!("bundle install")
    run!("rails generate rspec:install")
  end

  # SaturnCI loads the schema with db:schema:load, so db/schema.rb has to exist.
  def add_model_and_schema
    run!("rails generate model Widget name:string")
    run!("rails db:drop db:create db:migrate")
  end

  def add_passing_spec
    File.write("spec/models/widget_spec.rb", <<~RSPEC)
      require 'rails_helper'

      RSpec.describe Widget, type: :model do
        it "can be created" do
          widget = Widget.create!(name: "test widget")
          expect(widget).to be_persisted
        end
      end
    RSPEC
  end

  # A browser-driven spec only passes if the template's Capybara config points
  # the browser container at the app container.
  def add_system_spec
    @io.puts "Adding system spec..."
    gemfile = File.read("Gemfile")
    gemfile = gemfile.gsub(
      /(group :development, :test do\n)/,
      "\\1  gem \"capybara\"\n  gem \"selenium-webdriver\"\n"
    )
    File.write("Gemfile", gemfile)

    run!("bundle install")
    run!("rails generate controller Pages home")

    FileUtils.mkdir_p("spec/system")
    File.write("spec/system/home_page_spec.rb", <<~RSPEC)
      require 'rails_helper'

      RSpec.describe "Home page", type: :system do
        it "shows the page" do
          visit "/pages/home"
          expect(page).to have_content("Pages#home")
        end
      end
    RSPEC
  end

  def commit_app
    @io.puts "Committing initial Rails app with RSpec..."
    # This workflow file needs permissions the test account does not have.
    system("rm -rf .github")
    run!("git add .")
    run!("git commit -m 'Initial Rails app with RSpec test suite'")
  end

  def apply_template
    @io.puts "Applying SaturnCI template..."
    run!("rails app:template LOCATION=#{TEMPLATE_PATH}")
  end

  def commit_template
    @io.puts "Committing SaturnCI configuration..."
    run!("git add .")
    run!("git commit -m 'Add SaturnCI configuration via Rails template'")
    capture("git rev-parse HEAD")
  end

  def push
    @io.puts "Pushing to #{FIXTURE_REPO}..."
    push_url = "https://x-access-token:#{github_token}@github.com/#{FIXTURE_REPO}.git"
    with_github_retries { force_push(push_url) }
  end

  def force_push(push_url)
    output = `git push #{push_url} main --force 2>&1`.gsub(github_token, "[REDACTED]")
    @io.puts output
    return if $?.success?
    raise GitHubConnectionError, "git push could not reach GitHub" if output.include?("unable to access")

    raise "git push failed"
  end

  def with_github_retries
    retry_count = 0

    begin
      yield
    rescue *GITHUB_CONNECTION_ERRORS => error
      raise if retry_count == GITHUB_MAX_RETRY_COUNT

      retry_count += 1
      @io.puts "GitHub connection failed (#{error.class}: #{error.message}); " \
               "retry #{retry_count} of #{GITHUB_MAX_RETRY_COUNT}."
      GITHUB_RETRY_INTERVAL_SECONDS.downto(1) do |seconds_remaining|
        @io.puts "Retrying in #{seconds_remaining}s..."
        sleep 1
      end
      retry
    end
  end

  def github_token
    @github_token ||= @env.fetch(GITHUB_TOKEN_VAR)
  end

  # The assertion the original script lacked.
  def wait_for_test_suite_run(commit_hash)
    @io.puts "Waiting for test_suite_run for commit #{commit_hash}..."

    test_suite_run = wait_for_run_to_appear(commit_hash)
    return 1 unless test_suite_run

    @io.puts "Found test_suite_run #{test_suite_run.id}; waiting for completion..."
    status = wait_for_completion_with_progress(test_suite_run.id)
    @io.puts "test_suite_run finished: #{status}"

    return 0 if normalize(status) == PASSED_STATUS

    @error_io.puts "Expected the generated app's test suite to pass, got #{status}"
    1
  end

  # The agent forwards this to every job, so the job needs no SaturnCI secret of
  # its own.
  # Both waits below are otherwise silent for minutes at a time, which reads as a
  # wedged job rather than a waiting one. Report elapsed time as we go.
  def wait_for_run_to_appear(commit_hash)
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    loop do
      test_suite_run = SaturnCI::TestSuiteRun.list(
        client: saturnci_client,
        commit_hash: commit_hash
      ).first
      return test_suite_run if test_suite_run

      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

      if elapsed > RUN_APPEARANCE_TIMEOUT_SECONDS
        @error_io.puts "No test_suite_run appeared for #{commit_hash} within " \
                       "#{RUN_APPEARANCE_TIMEOUT_SECONDS}s. Is #{FIXTURE_REPO} added to SaturnCI, " \
                       "and can this job's token see its runs?"
        return nil
      end

      @io.puts "  ...no test_suite_run after #{elapsed.round}s of #{RUN_APPEARANCE_TIMEOUT_SECONDS}s"
      sleep POLL_INTERVAL_SECONDS
    end
  end

  # Polls the API directly rather than using the SDK: the version pinned in this
  # environment has no TestSuiteRun.find, and its list() does not populate
  # status. Returns the terminal status as a string, e.g. "Passed".
  def wait_for_completion_with_progress(test_suite_run_id)
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    loop do
      status = test_suite_run_status(test_suite_run_id)
      return status if TERMINAL_STATUSES.include?(normalize(status))

      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
      @io.puts "  ...test_suite_run #{status} after #{elapsed.round}s"
      sleep POLL_INTERVAL_SECONDS
    end
  end

  def test_suite_run_status(test_suite_run_id)
    response = saturnci_client.get("/api/v1/test_suite_runs/#{test_suite_run_id}")
    JSON.parse(response.body).fetch("status")
  end

  def normalize(status)
    status.to_s.downcase.tr(" ", "_")
  end

  def saturnci_client
    SaturnCI::Client.new(
      SaturnCI::Credentials.new(api_token: @env.fetch("SATURNCI_ACCESS_TOKEN"))
    )
  end

  def run!(command)
    system(command) || raise("Command failed: #{command}")
  end

  def capture(command)
    output = `#{command}`.strip
    raise "Command failed: #{command}" unless $?.success?

    output
  end
end

if $PROGRAM_NAME == __FILE__
  $stdout.sync = true
  $stderr.sync = true
  exit RailsTemplateJob.new.perform
end
