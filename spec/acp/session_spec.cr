require "../spec_helper"
require "../../src/acp/server"

# External-prompt delivery in ACP sessions: a failed CI build must inject
# its failure-log excerpt into the agent's context as a prompt — queued as
# a follow-up turn while a turn runs, or self-started while idle — so the
# model never has to fetch and parse CI logs itself. Driven end-to-end by
# the offline MockProvider (no network, no API key).

module H2code::Acp
  # Minimal tool whose execution fires a callback — lets a scripted mock
  # turn deliver an external notification mid-turn.
  class HookTool < H2code::Tools::Tool
    def initialize(&@hook : -> Nil)
    end

    def name : String
      "ci_hook"
    end

    def description : String
      "Test hook: fires the external delivery callback"
    end

    def parameters : JSON::Any
      JSON.parse(%({"type":"object","properties":{},"required":[],"additionalProperties":false}))
    end

    def execute(input : JSON::Any) : H2code::Tools::ToolResult
      @hook.try(&.call)
      H2code::Tools::ToolResult.success("hook fired")
    end
  end

  # Builds a Session over a scripted MockProvider (no network): agent,
  # registry, store in a tmpdir, and an in-memory JsonRpc pair.
  def self.acp_test_session(script : Array(H2code::LLM::MockStep), &)
    with_tmpdir do |dir|
      provider = H2code::LLM::MockProvider.new(script)
      memory = H2code::Context::Memory.new
      memory.max_context_tokens = 131_072
      tools = H2code::Tools::Registry.new
      permission = H2code::Permission::Manager.new(H2code::Permission::Mode::Yolo)
      agent = H2code::Loop::Agent.new(provider, memory, tools, permission)
      store = H2code::Session::Store.new(File.join(dir, "session"))
      rpc = JsonRpc.new(IO::Memory.new, IO::Memory.new)
      session = Session.new("s1", agent, store, rpc, "system")
      yield session, tools, store
    end
  end

  # All turn.prompt texts recorded in the session wire log.
  def self.acp_test_prompts(store : H2code::Session::Store) : Array(String)
    store.read_events.select { |evt| evt[:type] == "turn.prompt" }
      .map { |evt| evt[:data]["prompt"].to_s }
  end

  describe Session do
    it "runs a notification delivered mid-turn as a follow-up turn" do
      notification = %(<notification id="ci.#{"d" * 40}.failure">CI build failed\nFailure log (excerpt):\nexpected true, got false\n</notification>)
      script = [
        # Main turn: a tool call whose execution enqueues the CI
        # notification while the turn is busy.
        H2code::LLM::MockStep.new(
          parts: [H2code::LLM::ToolCallPart.new("c1", "ci_hook", %({}))] of H2code::LLM::MessagePart,
          stop_reason: "tool_use"),
        # Main turn's completion step.
        H2code::LLM::MockStep.new(
          parts: [H2code::LLM::TextPart.new("main turn done")] of H2code::LLM::MessagePart,
          stop_reason: "end_turn",
          text: "main turn done"),
        # The follow-up turn's step.
        H2code::LLM::MockStep.new(
          parts: [H2code::LLM::TextPart.new("fixing the build")] of H2code::LLM::MessagePart,
          stop_reason: "end_turn",
          text: "fixing the build"),
      ]

      H2code::Acp.acp_test_session(script) do |session, tools, store|
        tools.register(HookTool.new { session.deliver_external_prompt(notification) })

        result = session.prompt("run the build")

        result["stopReason"].to_s.should eq("end_turn")
        H2code::Acp.acp_test_prompts(store).should eq(["run the build", notification])
      end
    end

    it "self-starts a turn when a notification arrives while idle" do
      notification = %(<notification id="ci.#{"e" * 40}.failure">CI build failed\nFailure log (excerpt):\nboom\n</notification>)
      script = [
        H2code::LLM::MockStep.new(
          parts: [H2code::LLM::TextPart.new("on it")] of H2code::LLM::MessagePart,
          stop_reason: "end_turn",
          text: "on it"),
      ]

      H2code::Acp.acp_test_session(script) do |session, _tools, store|
        session.deliver_external_prompt(notification)

        deadline = Time.instant + 2.seconds
        while H2code::Acp.acp_test_prompts(store).empty? && Time.instant < deadline
          sleep 10.milliseconds
        end
        H2code::Acp.acp_test_prompts(store).should eq([notification])
      end
    end

    it "delivers a notification with the same id exactly once" do
      # The plain-text CI format: bracketed marker line + readable body
      # (what Ci.render_notification produces since the XML envelope drop).
      notification = %([notification id="ci.#{"f" * 40}.failure"]\nCI build failed\nFailure log (excerpt):\nboom)
      script = [
        H2code::LLM::MockStep.new(
          parts: [H2code::LLM::TextPart.new("on it")] of H2code::LLM::MessagePart,
          stop_reason: "end_turn",
          text: "on it"),
        H2code::LLM::MockStep.new(
          parts: [H2code::LLM::TextPart.new("still on it")] of H2code::LLM::MessagePart,
          stop_reason: "end_turn",
          text: "still on it"),
      ]

      H2code::Acp.acp_test_session(script) do |session, _tools, store|
        2.times { session.deliver_external_prompt(notification) }

        deadline = Time.instant + 2.seconds
        while H2code::Acp.acp_test_prompts(store).empty? && Time.instant < deadline
          sleep 10.milliseconds
        end
        sleep 100.milliseconds # a duplicate delivery would land here
        H2code::Acp.acp_test_prompts(store).should eq([notification])
      end
    end
  end
end
