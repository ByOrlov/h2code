require "../spec_helper"
require "../../src/tools/plan_mode"
require "file_utils"

private def with_plan_service(&)
  dir = File.join(ENV["TMPDIR"]? || "/tmp", "plan_mode_spec_#{Random::Secure.hex(8)}")
  Dir.mkdir_p(dir)
  service = H2code::Tools::AgentPlanService.new(dir, "agent-test", File.join(dir, "plan.md"))
  H2code::Tools::PlanMode.plan_service = service
  H2code::Tools::PlanMode.permission_mode = nil
  H2code::Tools::PlanMode.plan_review_service = nil
  begin
    yield service, dir
  ensure
    H2code::Tools::PlanMode.plan_service = nil
    H2code::Tools::PlanMode.permission_mode = nil
    H2code::Tools::PlanMode.plan_review_service = nil
    FileUtils.rm_rf(dir)
  end
end

describe H2code::Tools::EnterPlanMode do
  it "exposes JS-name and identical schema" do
    tool = H2code::Tools::EnterPlanMode.new
    tool.name.should eq(H2code::Tools::Names::ENTER_PLAN_MODE)
    tool.description.should contain("non-trivial implementation")

    tool.parameters["properties"].as_h.empty?.should be_true
    tool.parameters["additionalProperties"].as_bool.should be_false
  end

  it "fails when plan mode is already active" do
    with_plan_service do |service|
      service.enter
      tool = H2code::Tools::EnterPlanMode.new
      result = tool.execute(JSON.parse(%({})))
      result.is_error?.should be_true
      result.content.should contain("already active")
    end
  end

  it "enters plan mode and returns message with plan file" do
    with_plan_service do |service|
      tool = H2code::Tools::EnterPlanMode.new
      result = tool.execute(JSON.parse(%({})))
      result.is_error?.should be_false
      result.content.should contain("Plan mode is now active")
      result.content.should contain("Plan file:")
      result.content.should contain("Write the plan to the plan file")
      service.status.should_not be_nil
    end
  end

  it "renders message without path when plan_path is nil" do
    # Custom service that keeps path nil even after enter.
    service = H2code::Tools::PlanServiceSpecHelper::NoPathPlanService.new
    H2code::Tools::PlanMode.plan_service = service
    tool = H2code::Tools::EnterPlanMode.new
    result = tool.execute(JSON.parse(%({})))
    result.is_error?.should be_false
    result.content.should contain("no plan file path is available")
    H2code::Tools::PlanMode.plan_service = nil
  end

  it "fails when no service is registered" do
    H2code::Tools::PlanMode.plan_service = nil
    tool = H2code::Tools::EnterPlanMode.new
    result = tool.execute(JSON.parse(%({})))
    result.is_error?.should be_true
    result.content.should contain("Plan service is not initialized")
  end
end

describe H2code::Tools::ExitPlanMode do
  it "exposes JS-name and identical schema" do
    tool = H2code::Tools::ExitPlanMode.new
    tool.name.should eq(H2code::Tools::Names::EXIT_PLAN_MODE)
    tool.description.should contain("plan mode")
    props = tool.parameters["properties"].as_h
    props.has_key?("options").should be_true
    tool.parameters["additionalProperties"].as_bool.should be_false
  end

  it "auto-enters plan mode when not active, then reports the missing plan file" do
    with_plan_service do |service|
      tool = H2code::Tools::ExitPlanMode.new
      result = tool.execute(JSON.parse(%({})))
      # Принудительно вошли в plan mode.
      service.status.should_not be_nil
      # Плана ещё нет — ожидаем recover-ошибку с путём к файлу плана.
      result.is_error?.should be_true
      result.content.should contain("No plan file found")
      result.content.should contain("plan.md")
    end
  end

  it "fails when plan file is empty (path known)" do
    with_plan_service do |service, _|
      service.enter
      tool = H2code::Tools::ExitPlanMode.new
      result = tool.execute(JSON.parse(%({})))
      result.is_error?.should be_true
      result.content.should contain("No plan file found")
      result.content.should contain("plan.md")
    end
  end

  it "exits plan mode in auto permission mode with auto-approved message" do
    with_plan_service do |service, dir|
      path = File.join(dir, "plan.md")
      File.write(path, "## Plan\n\nStep 1: do thing.\n")
      service.enter

      H2code::Tools::PlanMode.permission_mode = H2code::Tools::PermissionModeRef.new(auto: true)

      tool = H2code::Tools::ExitPlanMode.new
      result = tool.execute(JSON.parse(%({})))
      result.is_error?.should be_false
      result.content.should contain("Exited plan mode")
      result.content.should contain("auto-approved without user review")
      result.content.should contain("## Plan (auto-approved")
      result.content.should contain("Step 1: do thing.")
      service.status.should be_nil
    end
  end

  it "exits plan mode in manual mode with approved message" do
    with_plan_service do |service, dir|
      path = File.join(dir, "plan.md")
      File.write(path, "Plan body.")
      service.enter

      H2code::Tools::PlanMode.permission_mode = H2code::Tools::PermissionModeRef.new(auto: false)

      tool = H2code::Tools::ExitPlanMode.new
      result = tool.execute(JSON.parse(%({})))
      result.is_error?.should be_false
      result.content.should contain("Exited plan mode")
      result.content.should contain("## Approved Plan:")
      result.content.should contain("Plan body.")
    end
  end

  # ── Interactive review branches (manual / yolo with a PlanReviewService) ──

  it "approves via the review service and exits plan mode" do
    with_plan_service do |service, dir|
      File.write(File.join(dir, "plan.md"), "The plan.")
      service.enter
      H2code::Tools::PlanMode.permission_mode = H2code::Tools::PermissionModeRef.new(auto: false)
      H2code::Tools::PlanMode.plan_review_service =
        H2code::Tools::PlanServiceSpecHelper::MockReviewService.new(
          H2code::Tools::PlanReviewDecision::Approve)

      tool = H2code::Tools::ExitPlanMode.new
      result = tool.execute(JSON.parse(%({})))
      result.is_error?.should be_false
      result.content.should contain("Exited plan mode")
      result.content.should contain("## Approved Plan:")
      result.content.should contain("The plan.")
      service.status.should be_nil
    end
  end

  it "approves with a selected option and prefixes the chosen approach" do
    with_plan_service do |service, dir|
      File.write(File.join(dir, "plan.md"), "Multi-approach plan.")
      service.enter
      H2code::Tools::PlanMode.permission_mode = H2code::Tools::PermissionModeRef.new(auto: false)
      H2code::Tools::PlanMode.plan_review_service =
        H2code::Tools::PlanServiceSpecHelper::MockReviewService.new(
          H2code::Tools::PlanReviewDecision::Approve,
          selected_label: "Approach A")

      tool = H2code::Tools::ExitPlanMode.new
      result = tool.execute(JSON.parse(%({
        "options": [{"label": "Approach A", "description": "first"}, {"label": "Approach B"}]
      })))
      result.is_error?.should be_false
      result.content.should contain("Selected approach: Approach A")
      result.content.should contain("Execute ONLY the selected approach")
      result.content.should contain("## Approved Plan:")
    end
  end

  it "revise keeps plan mode active and surfaces feedback" do
    with_plan_service do |service, dir|
      File.write(File.join(dir, "plan.md"), "Draft.")
      service.enter
      H2code::Tools::PlanMode.permission_mode = H2code::Tools::PermissionModeRef.new(auto: false)
      H2code::Tools::PlanMode.plan_review_service =
        H2code::Tools::PlanServiceSpecHelper::MockReviewService.new(
          H2code::Tools::PlanReviewDecision::Revise,
          feedback: "Add more detail to step 2")

      tool = H2code::Tools::ExitPlanMode.new
      result = tool.execute(JSON.parse(%({})))
      result.is_error?.should be_false
      result.content.should contain("User rejected the plan. Feedback:")
      result.content.should contain("Add more detail to step 2")
      # Plan mode stays active.
      service.status.should_not be_nil
    end
  end

  it "revise without feedback keeps plan mode active" do
    with_plan_service do |service, dir|
      File.write(File.join(dir, "plan.md"), "Draft.")
      service.enter
      H2code::Tools::PlanMode.permission_mode = H2code::Tools::PermissionModeRef.new(auto: false)
      H2code::Tools::PlanMode.plan_review_service =
        H2code::Tools::PlanServiceSpecHelper::MockReviewService.new(
          H2code::Tools::PlanReviewDecision::Revise)

      tool = H2code::Tools::ExitPlanMode.new
      result = tool.execute(JSON.parse(%({})))
      result.is_error?.should be_false
      result.content.should contain("User requested revisions. Plan mode remains active.")
      service.status.should_not be_nil
    end
  end

  it "reject & exit deactivates plan mode with an error" do
    with_plan_service do |service, dir|
      File.write(File.join(dir, "plan.md"), "Bad plan.")
      service.enter
      H2code::Tools::PlanMode.permission_mode = H2code::Tools::PermissionModeRef.new(auto: false)
      H2code::Tools::PlanMode.plan_review_service =
        H2code::Tools::PlanServiceSpecHelper::MockReviewService.new(
          H2code::Tools::PlanReviewDecision::RejectAndExit)

      tool = H2code::Tools::ExitPlanMode.new
      result = tool.execute(JSON.parse(%({})))
      result.is_error?.should be_true
      result.content.should contain("Plan rejected by user. Plan mode deactivated.")
      service.status.should be_nil
    end
  end

  it "dismissed (Esc) keeps plan mode active" do
    with_plan_service do |service, dir|
      File.write(File.join(dir, "plan.md"), "Plan.")
      service.enter
      H2code::Tools::PlanMode.permission_mode = H2code::Tools::PermissionModeRef.new(auto: false)
      H2code::Tools::PlanMode.plan_review_service =
        H2code::Tools::PlanServiceSpecHelper::MockReviewService.new(
          H2code::Tools::PlanReviewDecision::Dismissed)

      tool = H2code::Tools::ExitPlanMode.new
      result = tool.execute(JSON.parse(%({})))
      result.is_error?.should be_false
      result.content.should contain("Plan approval dismissed. Plan mode remains active.")
      service.status.should_not be_nil
    end
  end

  it "rejects duplicate option labels" do
    with_plan_service do |service, dir|
      File.write(File.join(dir, "plan.md"), "x")
      service.enter
      tool = H2code::Tools::ExitPlanMode.new
      result = tool.execute(JSON.parse(%({
        "options": [
          {"label": "Approach A"},
          {"label": "approach a"}
        ]
      })))
      result.is_error?.should be_true
      result.content.should contain("Option labels must be unique")
    end
  end

  it "rejects reserved option labels" do
    with_plan_service do |service, dir|
      File.write(File.join(dir, "plan.md"), "x")
      service.enter
      tool = H2code::Tools::ExitPlanMode.new
      result = tool.execute(JSON.parse(%({
        "options": [{"label": "Reject"}]
      })))
      result.is_error?.should be_true
      result.content.should contain("reserved approval labels")
    end
  end

  it "rejects too many options" do
    with_plan_service do |service, dir|
      File.write(File.join(dir, "plan.md"), "x")
      service.enter
      tool = H2code::Tools::ExitPlanMode.new
      result = tool.execute(JSON.parse(%({
        "options": [{"label":"A"},{"label":"B"},{"label":"C"},{"label":"D"}]
      })))
      result.is_error?.should be_true
      result.content.should contain("between 1 and 3")
    end
  end

  it "rejects empty option label" do
    with_plan_service do |service, dir|
      File.write(File.join(dir, "plan.md"), "x")
      service.enter
      tool = H2code::Tools::ExitPlanMode.new
      result = tool.execute(JSON.parse(%({
        "options": [{"label": ""}]
      })))
      result.is_error?.should be_true
      result.content.should contain("label")
    end
  end

  it "fails when no service is registered" do
    H2code::Tools::PlanMode.plan_service = nil
    tool = H2code::Tools::ExitPlanMode.new
    result = tool.execute(JSON.parse(%({})))
    result.is_error?.should be_true
    result.content.should contain("Plan service is not initialized")
  end
end

# Helpers for plan-mode specs.
module H2code::Tools::PlanServiceSpecHelper
  class NoPathPlanService < H2code::Tools::PlanService
    @active : Bool = false
    @id : String = "test-plan-id"

    def status : H2code::Tools::PlanData?
      return nil unless @active
      H2code::Tools::PlanData.new(id: @id, content: "", path: nil)
    end

    def enter(id : String? = nil, create_file : Bool = false) : Nil
      @active = true
    end

    def cancel(id : String? = nil) : Nil
      @active = false
    end

    def clear : Nil
      @active = false
    end

    def exit(id : String? = nil) : Nil
      @active = false
    end
  end

  # Scripted PlanReviewService: returns a fixed result, ignoring its inputs.
  # Lets the ExitPlanMode review branches be tested without a TUI.
  class MockReviewService < H2code::Tools::PlanReviewService
    def initialize(@result : H2code::Tools::PlanReviewResult)
    end

    def self.new(decision : H2code::Tools::PlanReviewDecision,
                 selected_label : String? = nil,
                 feedback : String = "")
      new(H2code::Tools::PlanReviewResult.new(decision, selected_label, feedback))
    end

    def request(plan : String, path : String?,
                options : Array(H2code::Tools::PlanOption)?) : H2code::Tools::PlanReviewResult?
      @result
    end
  end
end

# Regression for the fork-sandbox session-store write block (commit 303907a):
# plan files live under the session store, so writing them with the regular
# Write tool must stay possible while every other session-store path remains
# blocked.
describe H2code::Tools::PlanMode do
  it "Write tool can write the active plan file inside the session store" do
    home = File.join(ENV["TMPDIR"]? || "/tmp", "plan_write_home_#{Random::Secure.hex(8)}")
    work = File.join(ENV["TMPDIR"]? || "/tmp", "plan_write_work_#{Random::Secure.hex(8)}")
    Dir.mkdir_p(home)
    Dir.mkdir_p(work)
    session_dir = File.join(home, ".h2code", "sessions", "spec-session")

    old_home = ENV["HOME"]?
    ENV["HOME"] = home
    H2code::Sandbox.reset
    H2code::Sandbox.session_dir = session_dir
    old_service = H2code::Tools::PlanMode.plan_service
    service = H2code::Tools::AgentPlanService.new(session_dir, "main")
    H2code::Tools::PlanMode.plan_service = service

    begin
      service.enter
      plan_path = service.status.not_nil!.path.not_nil!

      write = H2code::Tools::Write.new(work)
      plan_json = {"path" => plan_path, "content" => "# Plan\n"}.to_json
      result = write.execute(JSON.parse(plan_json))
      result.is_error?.should be_false
      File.read(plan_path).should eq("# Plan\n")

      # A sibling session's dir stays blocked.
      sibling = File.join(home, ".h2code", "sessions", "other", "x.log")
      result = write.execute(JSON.parse({"path" => sibling, "content" => "x"}.to_json))
      result.is_error?.should be_true
      result.content.should contain("session data")
    ensure
      H2code::Tools::PlanMode.plan_service = old_service
      H2code::Sandbox.session_dir = nil
      H2code::Sandbox.reset
      ENV["HOME"] = old_home if old_home
      FileUtils.rm_rf(home)
      FileUtils.rm_rf(work)
    end
  end
end
