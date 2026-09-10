module H2code
  module LLM
    # One scripted step of a MockProvider replay: the MessageParts to stream
    # through the block and the stop_reason to report. A step whose stop_reason
    # is "tool_use" (or that carries tool_calls) forces the agent loop to
    # dispatch those calls in parallel and loop again; a step with no tool
    # calls and "end_turn" terminates the loop.
    struct MockStep
      property parts : Array(MessagePart)
      property stop_reason : String
      property text : String
      # Delay (ms) to sleep before emitting each part. Simulates network
      # streaming latency so the TUI's live render can be exercised.
      property part_delay_ms : Int32 = 0

      def initialize(@parts : Array(MessagePart), @stop_reason : String = "end_turn",
                     @text : String = "", @part_delay_ms : Int32 = 0)
      end
    end

    # Deterministic, offline provider for agent-loop integration tests and
    # token-free manual demos. Instead of calling an LLM it replays a fixed
    # script step by step: each `chat` call returns the next MockStep,
    # streaming its parts through the block exactly like a real provider, so
    # the agent's run_turn / parallel tool batch / termination all execute
    # against real tool calls — with no network or API key.
    #
    # Select it at runtime via `H2CODE_PROVIDER=mock` or `[provider] default =
    # "mock"` to exercise the loop without burning tokens.
    class MockProvider < Provider
      DEFAULT_MODEL = "mock"

      # Built-in self-test script: two parallel tool calls (Glob + Bash), then
      # a Write, then a final text step with no tool calls so the loop stops.
      DEFAULT_SCRIPT = [
        MockStep.new(
          parts: [
            ToolCallPart.new("m_call_1", Tools::Names::GLOB, %({"pattern":"*"})),
            ToolCallPart.new("m_call_2", Tools::Names::BASH, %({"command":"echo mock-selftest-ok"})),
          ] of MessagePart,
          stop_reason: "tool_use",
        ),
        MockStep.new(
          parts: [ToolCallPart.new("m_call_fail", Tools::Names::BASH, %({"command":"echo step2"}))] of MessagePart,
          stop_reason: "tool_use",
        ),
        MockStep.new(
          parts: [ToolCallPart.new("m_call_3", Tools::Names::WRITE, %({"path":".mock-selftest","content":"mock ran"}))] of MessagePart,
          stop_reason: "tool_use",
        ),
        MockStep.new(
          parts: [TextPart.new("Mock self-test complete.")] of MessagePart,
          stop_reason: "end_turn",
          text: "Mock self-test complete.",
        ),
      ] of MockStep

      # Thinking-only demo: ~5 s of streamed reasoning (10 ThinkParts × 500 ms),
      # then a short text answer. Use with:
      #   H2CODE_PROVIDER=mock H2CODE_MOCK_SCRIPT=thinking
      THINKING_DEMO_SCRIPT = [
        MockStep.new(
          parts: [
            ThinkPart.new("Let me analyze this request carefully."),
            ThinkPart.new(" The user wants me to examine the project structure."),
            ThinkPart.new(" I should start by checking the configuration files"),
            ThinkPart.new(" like shard.yml to understand the dependencies."),
            ThinkPart.new(" Then I need to look at the source directory layout"),
            ThinkPart.new(" to understand how modules are organized."),
            ThinkPart.new(" I also want to review the main entry point"),
            ThinkPart.new(" and trace how the agent loop is initialized."),
            ThinkPart.new(" After that, I can formulate a clear answer"),
            ThinkPart.new(" summarizing the architecture for the user."),
            TextPart.new("I've analyzed the project. It's a Crystal agent with an LLM provider layer, a tool registry, and a TUI."),
          ] of MessagePart,
          stop_reason: "end_turn",
          text: "I've analyzed the project. It's a Crystal agent with an LLM provider layer, a tool registry, and a TUI.",
          part_delay_ms: 500,
        ),
      ] of MockStep

      # Thinking + tools demo: ~3 s of reasoning, then a Glob tool call, then
      # a final text answer. Tests the thinking → tool-call transition.
      #   H2CODE_PROVIDER=mock H2CODE_MOCK_SCRIPT=thinking-tools
      THINKING_TOOLS_DEMO_SCRIPT = [
        MockStep.new(
          parts: [
            ThinkPart.new("Let me think about what files to examine."),
            ThinkPart.new(" I should list the source files first."),
            ThinkPart.new(" A Glob call with pattern \"src/**/*.cr\" would work."),
            ThinkPart.new(" Let me do that now."),
            ToolCallPart.new("m_think_1", Tools::Names::GLOB, %({"pattern":"src/**/*.cr"})),
          ] of MessagePart,
          stop_reason: "tool_use",
          part_delay_ms: 600,
        ),
        MockStep.new(
          parts: [
            TextPart.new("I found the source files. The project is well-organized."),
          ] of MessagePart,
          stop_reason: "end_turn",
          text: "I found the source files. The project is well-organized.",
        ),
      ] of MockStep

      # Markdown rendering demo: streams a reply that exercises the TUI's
      # markdown renderer — headings, emphasis, inline code, lists, a fenced
      # code block, a table, a blockquote and a horizontal rule. Use with:
      #   H2CODE_PROVIDER=mock H2CODE_MOCK_SCRIPT=markdown
      # Long (~200-line) streamed preamble so the TUI exercises scrolling and
      # incremental render over a large reply, before the markdown showcase.
      # Each line carries a `Line N of T:` prefix and an alternating `----`/`+`
      # postfix marker, making it easy to verify line-by-line streaming render.
      def self.build_markdown_long_preamble : String
        b = String::Builder.new
        b << "# Markdown Rendering Demo\n\n"
        b << "This reply exercises the terminal **markdown** renderer "
        b << "after a long streamed preamble so scroll behaviour can be checked.\n\n"
        b << "## Long preamble\n\n"
        total = 200
        postfixes = {" ----", " +"}
        total.times do |i|
          b << "Line #{i + 1} of #{total}: streamed assistant token, rendered inside the active chat block. "
          b << postfixes[i % 2]
          b << "\n"
        end
        b << "\n"
        b.to_s
      end

      MARKDOWN_DEMO_SCRIPT = [
        # Stage 1 — long streamed preamble (~200 lines) that exercises
        # scrolling and incremental render, then a Read tool call so the
        # tool-call path runs between the two text stages.
        MockStep.new(
          parts: [
            TextPart.new(build_markdown_long_preamble),
            ToolCallPart.new("m_md_read_1", Tools::Names::READ, %({"path":"README.md"})),
          ] of MessagePart,
          stop_reason: "tool_use",
          part_delay_ms: 80,
        ),
        # Stage 2 — markdown showcase, its own streamed stage.
        MockStep.new(
          parts: [
            TextPart.new("## Markdown showcase\n\n"),
            TextPart.new("It has *italics*, `inline code`, and a [link](https://example.com).\n\n"),
            TextPart.new("## Unordered list\n\n"),
            TextPart.new("- First item\n- Second item\n- Third item\n\n"),
            TextPart.new("## Ordered steps\n\n"),
            TextPart.new("1. Read the source\n2. Run the tests\n3. Ship it\n\n"),
            TextPart.new("## Code block\n\n"),
            TextPart.new("```crystal\n"),
            TextPart.new("def greet(name : String)\n  puts \"Hello, \#{name}!\"\nend\n\n"),
            TextPart.new("greet(\"world\")\n\n"),
            TextPart.new("# block syntax with pipes — must NOT render as a table\n"),
            TextPart.new("[1, 2, 3].each do | n |\n  puts n\nend\n"),
            TextPart.new("```\n\n"),
            TextPart.new("## Table\n\n"),
            TextPart.new("| File | Purpose |\n| --- | --- |\n| `src/h2code.cr` | Entry point |\n| `src/llm/` | Provider layer |\n| `src/tui/` | Terminal UI |\n| `src/tui/markdown.cr` | Markdown renderer with ANSI-aware wrapping, cell overflow, and inline code styling — handles tables, lists, blockquotes, code fences, horizontal rules, headings, bold, italic, strikethrough, links, task lists, nested structures, wide characters, emoji width measurement, and proportional column shrinking when content exceeds terminal width |\n\n"),
            TextPart.new("> Markdown renders cleanly in the terminal.\n\n"),
            TextPart.new("---\n\n"),
            TextPart.new("That covers every block the renderer supports."),
          ] of MessagePart,
          stop_reason: "end_turn",
          text: "Markdown rendering demo complete.",
          part_delay_ms: 80,
        ),
      ] of MockStep

      # Broken-token markdown streaming bug repro: a 10-item list is delivered
      # so that each new "-" marker is split across chunks ("\n-" followed by
      # " Item N"). The transient "-" is parsed as a paragraph line, adding an
      # extra blank line; when the next token arrives it is re-absorbed into the
      # list item and the blank line disappears. This makes the Active zone
      # shrink/grow on every list item and drives SyncBugsCount up.
      # Use with: H2CODE_PROVIDER=mock H2CODE_MOCK_SCRIPT=markdown_tokens
      MARKDOWN_TOKENS_DEMO_SCRIPT = [
        MockStep.new(
          parts: [
            TextPart.new("Here "),
            TextPart.new("is "),
            TextPart.new("a "),
            TextPart.new("broken-token "),
            TextPart.new("markdown "),
            TextPart.new("list:\n"),
            TextPart.new("\n"),
            TextPart.new("- Item 1"),
            TextPart.new("\n-"),
            TextPart.new(" Item 2"),
            TextPart.new("\n-"),
            TextPart.new(" Item 3"),
            TextPart.new("\n-"),
            TextPart.new(" Item 4"),
            TextPart.new("\n-"),
            TextPart.new(" Item 5"),
            TextPart.new("\n-"),
            TextPart.new(" Item 6"),
            TextPart.new("\n-"),
            TextPart.new(" Item 7"),
            TextPart.new("\n-"),
            TextPart.new(" Item 8"),
            TextPart.new("\n-"),
            TextPart.new(" Item 9"),
            TextPart.new("\n-"),
            TextPart.new(" Item 10"),
            TextPart.new("\n\n"),
            TextPart.new("Streaming complete."),
          ] of MessagePart,
          stop_reason: "end_turn",
          text: "Broken-token markdown list demo complete.",
          part_delay_ms: 250,
        ),
      ] of MockStep

      # Sudo terminal-exec demo: a Bash call with `sudo` that triggers the
      # alt-screen terminal path (real /dev/tty for password entry), then a
      # final text answer. Requires `bin/mocksudo` on PATH or a real sudo.
      #   H2CODE_PROVIDER=mock H2CODE_MOCK_SCRIPT=sudo
      SUDO_DEMO_SCRIPT = [
        MockStep.new(
          parts: [
            TextPart.new("I'll run a sudo command to demonstrate terminal exec."),
            ToolCallPart.new("m_sudo_1", Tools::Names::BASH, %({"command":"sudo echo \\"Hello from sudo\\""})),
          ] of MessagePart,
          stop_reason: "tool_use",
        ),
        MockStep.new(
          parts: [TextPart.new("Sudo command completed successfully.")] of MessagePart,
          stop_reason: "end_turn",
          text: "Sudo command completed successfully.",
        ),
      ] of MockStep

      # TodoList migration demo: progressively completes a 3-item plan. The
      # panel lives in the active zone while work is underway; the moment every
      # item is `done`, the TUI freezes it as a `todo_snapshot` message (migrates
      # into the append-only log) and clears the tool so a fresh list can start.
      # The 1 s delays make the active-zone → log-zone transition visible.
      #   H2CODE_PROVIDER=mock H2CODE_MOCK_SCRIPT=todos
      TODOS_DEMO_SCRIPT = [
        MockStep.new(
          parts: [ToolCallPart.new("m_todo_1", Tools::Names::TODO_LIST, %({"todos":[{"title":"Analyze codebase","status":"in_progress"},{"title":"Write the fix","status":"pending"},{"title":"Run the test suite","status":"pending"}]}))] of MessagePart,
          stop_reason: "tool_use",
          part_delay_ms: 400,
        ),
        MockStep.new(
          parts: [ToolCallPart.new("m_todo_2", Tools::Names::TODO_LIST, %({"todos":[{"title":"Analyze codebase","status":"done"},{"title":"Write the fix","status":"in_progress"},{"title":"Run the test suite","status":"pending"}]}))] of MessagePart,
          stop_reason: "tool_use",
          part_delay_ms: 1000,
        ),
        MockStep.new(
          parts: [ToolCallPart.new("m_todo_3", Tools::Names::TODO_LIST, %({"todos":[{"title":"Analyze codebase","status":"done"},{"title":"Write the fix","status":"done"},{"title":"Run the test suite","status":"in_progress"}]}))] of MessagePart,
          stop_reason: "tool_use",
          part_delay_ms: 1000,
        ),
        MockStep.new(
          parts: [ToolCallPart.new("m_todo_4", Tools::Names::TODO_LIST, %({"todos":[{"title":"Analyze codebase","status":"done"},{"title":"Write the fix","status":"done"},{"title":"Run the test suite","status":"done"}]}))] of MessagePart,
          stop_reason: "tool_use",
          part_delay_ms: 1000,
        ),
        MockStep.new(
          parts: [TextPart.new("All tasks complete — the finished plan snapshot migrated into the log.")] of MessagePart,
          stop_reason: "end_turn",
          text: "All tasks complete — the finished plan snapshot migrated into the log.",
        ),
      ] of MockStep

      # Plan-review demo: enters plan mode, writes a long (~200-line) plan to
      # the plan file, then calls ExitPlanMode so the TUI surfaces the
      # PlanReviewDialog. The Write step targets the sentinel path
      # `__PLAN_FILE__`, which `MockProvider#chat` substitutes at runtime with
      # the real plan path from `PlanMode.plan_service` (only known after
      # EnterPlanMode executes). Use with:
      #   H2CODE_PROVIDER=mock H2CODE_MOCK_SCRIPT=plan
      PLAN_SENTINEL = "__PLAN_FILE__"

      def self.build_plan_content : String
        b = String::Builder.new
        b << "# Implement the full-plan viewer feature\n\n"
        b << "## Goal\n\n"
        b << "Add a scrollable full-screen plan viewer to the plan-review dialog, "
        b << "triggered by a `View full plan` action alongside Approve / Revise. "
        b << "This plan is intentionally long so the scroll behaviour can be exercised.\n\n"
        b << "## Background\n\n"
        b << "- `PlanReviewDialog` currently clamps the rendered plan body to 40 lines.\n"
        b << "- Long plans get truncated, leaving the user unable to read the full plan.\n"
        b << "- `TasksBrowser` already demonstrates the full-screen takeover pattern.\n\n"
        b << "## Approach\n\n"
        b << "Mirror `TasksBrowser`: add a `viewing_full` mode to the dialog that, when "
        b << "active, the App renders as a full-screen modal in the active zone.\n\n"
        sections = [
          {"Investigate the existing dialog", [
            "Read `src/tui/plan_review_dialog.cr` end to end.",
            "Read `src/tui/app.cr` render + input routing for the dialog.",
            "Read `src/tui/tasks_browser.cr` to mirror the takeover pattern.",
            "Note the ACTIONS list and the number-key hotkey handling.",
            "Note how `render_plan_body` clamps to 40 lines.",
          ]},
          {"Add the viewer state", [
            "Add `@viewing_full : Bool`, `@full_scroll`, `@full_lines`.",
            "Add `property rows` and `terminal_width=` set by the App.",
            "Reset the state in `show` and `hide`.",
            "Expose `getter? viewing_full`.",
            "Add `full_viewport` / `full_max_scroll` helpers.",
          ]},
          {"Add the action + input", [
            "Insert `View full plan` at index 0 of ACTIONS.",
            "Remap execute_action indices (1=Approve, 2=Revise, 3=Reject, 4=Cancel).",
            "Add `handle_full_view_input` for up/down/pgup/pgdn/home/end/esc/q/j/k.",
            "Build `@full_lines` lazily when entering the viewer.",
            "Update the footer hint to `1-5`.",
          ]},
          {"Render the viewer", [
            "Branch `render` to `render_full` when `viewing_full`.",
            "Render a header with path + (line/total) counter.",
            "Render the scroll window from `@full_lines`.",
            "Pad to the footer so short plans don't shift layout.",
            "Render a footer key-hint line.",
          ]},
          {"Wire the App", [
            "Set rows + terminal_width before handle_input.",
            "Add a full-screen takeover branch in build_rendered_lines_split.",
            "Gate the normal active-zone render on `!viewing_full`.",
            "Verify the build compiles cleanly.",
            "Run `rake mock:plan` and scroll the viewer end to end.",
          ]},
        ] of {String, Array(String)}
        sections.each_with_index do |(title, steps), si|
          b << "## Section #{si + 1} — #{title}\n\n"
          steps.each_with_index do |s, i|
            b << "#{si + 1}.#{i + 1}. #{s}\n"
            b << "   - Rationale: keep the change minimal and match surrounding style.\n"
            b << "   - Risk: low; isolated to the dialog and its App wiring.\n"
            b << "   - Verification: `crystal build src/h2code.cr` succeeds.\n"
          end
          b << "\n"
        end
        b << "## Detailed task breakdown\n\n"
        b << "Each task below maps to one focused commit. Verification is local only.\n\n"
        24.times do |i|
          b << "### Task #{i + 1}\n"
          b << "- Touch only the files listed in the relevant section above.\n"
          b << "- Keep the diff reviewable: no incidental reformatting.\n"
          b << "- Update any comment that now describes old behaviour.\n"
          b << "- Run the build, then run the relevant specs.\n"
          b << "- If behaviour is user-visible, note it in the commit message.\n\n"
        end
        b << "## Out of scope\n\n"
        b << "- Search-within-plan.\n"
        b << "- Persisting scroll position across reopens.\n"
        b << "- Side-by-side option preview.\n\n"
        b << "## Acceptance criteria\n\n"
        b << "- [ ] `View full plan` appears in the action list.\n"
        b << "- [ ] Selecting it opens a full-screen scrollable view.\n"
        b << "- [ ] All navigation keys work (↑↓, PgUp/PgDn, Home/End, j/k).\n"
        b << "- [ ] Esc / q returns to the action list.\n"
        b << "- [ ] The plan body is not truncated to 40 lines.\n"
        b.to_s
      end

      PLAN_DEMO_SCRIPT = [
        MockStep.new(
          parts: [ToolCallPart.new("m_plan_enter", Tools::Names::ENTER_PLAN_MODE, %q({}))] of MessagePart,
          stop_reason: "tool_use",
          part_delay_ms: 300,
        ),
        MockStep.new(
          parts: [ToolCallPart.new(
            "m_plan_write",
            Tools::Names::WRITE,
            %q({"path":") + PLAN_SENTINEL + %q(","content":") + build_plan_content.gsub('"', "\\\"").gsub('\n', "\\n") + %q("}),
          )] of MessagePart,
          stop_reason: "tool_use",
          part_delay_ms: 300,
        ),
        MockStep.new(
          parts: [ToolCallPart.new("m_plan_exit", Tools::Names::EXIT_PLAN_MODE, %q({}))] of MessagePart,
          stop_reason: "tool_use",
          part_delay_ms: 300,
        ),
        MockStep.new(
          parts: [TextPart.new("Plan submitted for review.")] of MessagePart,
          stop_reason: "end_turn",
          text: "Plan submitted for review.",
        ),
      ] of MockStep

      # Image delivery demo: reads an image via ReadMediaFile, then answers.
      # Exercises the multi-part tool result path — the image travels to the
      # provider as a native image_url content part, not inline base64 text.
      # The file defaults to logo.png; set H2CODE_MOCK_IMAGE to another path
      # (the rake mock:image task generates a text-rendering PNG via
      # ImageMagick so the demo is self-verifying). Use with:
      #   H2CODE_PROVIDER=mock H2CODE_MOCK_SCRIPT=image
      def self.image_demo_script : Array(MockStep)
        img_path = ENV["H2CODE_MOCK_IMAGE"]? || "logo.png"
        [
          MockStep.new(
            parts: [ToolCallPart.new("m_img_1", Tools::Names::READ_MEDIA_FILE, %({"path":"#{img_path}"}))] of MessagePart,
            stop_reason: "tool_use",
            part_delay_ms: 300,
          ),
          MockStep.new(
            parts: [TextPart.new("I've read #{img_path} as a native image content part. The media payload rode in the tool result's media channel, so no base64 bloated the text context.")] of MessagePart,
            stop_reason: "end_turn",
            text: "I've read #{img_path} as a native image content part. The media payload rode in the tool result's media channel, so no base64 bloated the text context.",
          ),
        ] of MockStep
      end

      property model : String
      property script : Array(MockStep)
      @step : Int32 = 0

      # Clipboard paste demo: the user pastes an image with Ctrl+V (the
      # clipboard is pointed at a file via H2CODE_CLIPBOARD_FILE, so the demo
      # is deterministic), the placeholder lands in the editor, and this
      # single-step script answers as if the image content part was received.
      #   H2CODE_PROVIDER=mock H2CODE_MOCK_SCRIPT=imagepaste
      IMAGEPASTE_DEMO_SCRIPT = [
        MockStep.new(
          parts: [TextPart.new("I can see the pasted image — it arrived as a native image_url content part in your message, no tool call needed. What would you like me to do with it?")] of MessagePart,
          stop_reason: "end_turn",
          text: "I can see the pasted image — it arrived as a native image_url content part in your message, no tool call needed. What would you like me to do with it?",
        ),
      ] of MockStep

      def initialize(@script : Array(MockStep) = DEFAULT_SCRIPT.dup, @model : String = DEFAULT_MODEL)
      end

      # Select a named demo script by the value configured in
      # `Config#mock_script` (originally the H2CODE_MOCK_SCRIPT env var, now
      # surfaced through Config). Returns nil when unset or unknown.
      def self.script_for(name : String?) : Array(MockStep)?
        case name
        when "thinking"        then THINKING_DEMO_SCRIPT.dup
        when "thinking-tools"  then THINKING_TOOLS_DEMO_SCRIPT.dup
        when "markdown"        then MARKDOWN_DEMO_SCRIPT.dup
        when "markdown_tokens" then MARKDOWN_TOKENS_DEMO_SCRIPT.dup
        when "sudo"            then SUDO_DEMO_SCRIPT.dup
        when "todos"           then TODOS_DEMO_SCRIPT.dup
        when "plan"            then PLAN_DEMO_SCRIPT.dup
        when "image"           then image_demo_script
        when "imagepaste"      then IMAGEPASTE_DEMO_SCRIPT.dup
        else                        nil
        end
      end

      def name : String
        "mock"
      end

      def model_name : String
        @model
      end

      def fetch_models : Array(String)
        [@model]
      end

      # Rewind the script to the first step (used between runs in tests).
      def reset : Nil
        @step = 0
      end

      # Demo-only substitution: the plan demo's Write step targets a sentinel
      # path because the real plan file path is only known after EnterPlanMode
      # runs. At chat-time we look it up from the live plan service and patch
      # the JSON arguments so the Write lands on the actual plan file.
      private def resolve_tool_arguments(name : String, args : String) : String
        return args unless name == Tools::Names::WRITE && args.includes?(PLAN_SENTINEL)
        path = H2code::Tools::PlanMode.plan_service.try(&.status).try(&.path) || ""
        return args if path.empty?
        # Linux paths contain no characters that need JSON escaping; a literal
        # substitution keeps the demo's synthesized JSON valid.
        args.gsub(PLAN_SENTINEL, path)
      end

      def chat(messages : Array(Message), tools : Array(ToolDefinition)?,
               system_prompt : String? = nil, aborted? : -> Bool = -> { false },
               &block : MessagePart ->) : StepResult
        current = @script[@step]? || @script.last
        @step += 1

        tool_calls = [] of ToolCall
        text = IO::Memory.new

        current.parts.each do |part|
          sleep current.part_delay_ms.milliseconds if current.part_delay_ms > 0
          case part
          when TextPart
            text << part.text
          when ToolCallPart
            args = resolve_tool_arguments(part.name, part.arguments)
            resolved = part
            unless args == part.arguments
              resolved = ToolCallPart.new(part.id, part.name, args)
            end
            tool_calls << ToolCall.new(resolved.id, ToolCallFunction.new(resolved.name, args))
            block.call(resolved)
            next
          end
          block.call(part)
        end

        usage = Usage.new(prompt_tokens: 10, completion_tokens: 5, total_tokens: 15)
        block.call(UsagePart.new(usage))
        block.call(FinishPart.new(current.stop_reason))

        StepResult.new(
          stop_reason: current.stop_reason,
          text: current.text.empty? ? text.to_s : current.text,
          tool_calls: tool_calls,
          usage: usage,
        )
      end
    end

    Provider.register("mock", "Mock — scripted self-test provider (testing)",
      label: "Mock (testing)", hidden: true) do |config, _|
      MockProvider.new(MockProvider.script_for(config.try(&.mock_script)) || MockProvider::DEFAULT_SCRIPT.dup)
    end
  end
end
