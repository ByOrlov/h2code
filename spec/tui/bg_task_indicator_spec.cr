require "../spec_helper"
require "../../src/tui/diff"

private def strip_ansi(line : String) : String
  line.gsub(/\e\[[0-9;]*m/, "")
end

private def make_task(id : String, status : H2code::Tools::AgentTaskStatus,
                      description : String = "build check",
                      started_at : Int64 = Time.utc.to_unix_ms - 42_000,
                      command : String? = nil,
                      detached : Bool? = nil) : H2code::Tools::AgentTaskInfo
  H2code::Tools::AgentTaskInfo.new(
    task_id: id,
    description: description,
    status: status,
    started_at: started_at,
    command: command,
    detached: detached,
  )
end

describe H2code::TUI::App do
  it "shows a wait line in the active zone while a background task runs" do
    app = H2code::TUI::App.new
    tasks = [make_task("task_1", H2code::Tools::AgentTaskStatus::Running)]
    app.on_fetch_tasks = -> : Array(H2code::Tools::AgentTaskInfo) { tasks }

    app.refresh_bg_tasks!
    lines, _editor_line, log_size = app.build_rendered_lines(80)
    active = lines[log_size..].map { |l| strip_ansi(l) }
    active.join('\n').should contain("task_1")
    active.join('\n').should contain("build check")
    active.join('\n').should contain("00:42")
  end

  it "falls back to the command when the description is empty" do
    app = H2code::TUI::App.new
    tasks = [make_task("task_2", H2code::Tools::AgentTaskStatus::Running,
      description: "", command: "npm run build")]
    app.on_fetch_tasks = -> : Array(H2code::Tools::AgentTaskInfo) { tasks }

    app.refresh_bg_tasks!
    lines, _editor_line, log_size = app.build_rendered_lines(80)
    active = lines[log_size..].map { |l| strip_ansi(l) }
    active.join('\n').should contain("npm run build")
  end

  it "emits a log summary and drops the wait line when the task finishes" do
    app = H2code::TUI::App.new
    running = [make_task("task_3", H2code::Tools::AgentTaskStatus::Running)]
    app.on_fetch_tasks = -> : Array(H2code::Tools::AgentTaskInfo) { running }
    app.refresh_bg_tasks!

    done = make_task("task_3", H2code::Tools::AgentTaskStatus::Completed,
      started_at: Time.utc.to_unix_ms - 90_000)
    done.ended_at = Time.utc.to_unix_ms
    done.exit_code = 0
    finished = [done]
    app.on_fetch_tasks = -> : Array(H2code::Tools::AgentTaskInfo) { finished }
    app.refresh_bg_tasks!

    lines, _editor_line, log_size = app.build_rendered_lines(80)
    active = lines[log_size..].map { |l| strip_ansi(l) }
    active.join('\n').should_not contain("task_3")

    log = lines[0...log_size].map { |l| strip_ansi(l) }
    log.join('\n').should contain("task_3")
    log.join('\n').should contain("completed")
    log.join('\n').should contain("exit 0")
  end

  it "ignores detached tasks and stays quiet when nothing runs" do
    app = H2code::TUI::App.new
    tasks = [make_task("task_4", H2code::Tools::AgentTaskStatus::Running, detached: true)]
    app.on_fetch_tasks = -> : Array(H2code::Tools::AgentTaskInfo) { tasks }

    app.refresh_bg_tasks!
    lines, _editor_line, log_size = app.build_rendered_lines(80)
    active = lines[log_size..].map { |l| strip_ansi(l) }
    active.join('\n').should_not contain("task_4")
  end
end
