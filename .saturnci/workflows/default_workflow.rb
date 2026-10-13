# SaturnCI runs this file on every push to this repo. It checks that the Rails
# template in this commit produces an app whose test suite passes in SaturnCI.
class DefaultWorkflow
  def initialize(env: ENV)
    @env = env
  end

  def perform(io: $stdout)
    rails_template_job_run = workflow_run.job_runs.create(
      job_name: "rails_template",
      task_adapter_name: "shell",
      idempotent: true
    )

    rails_template_job_run.start

    io.puts "Started rails_template job run: id=#{rails_template_job_run.id} url=#{rails_template_job_run.url}"

    workflow_run.finish if rails_template_job_run_finished?
  end

  private

  def rails_template_job_run_finished?
    rails_template_job_run = workflow_run.job_runs.list(job_name: "rails_template").first
    return false unless rails_template_job_run

    rails_template_job_run.passed? || rails_template_job_run.failed?
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
