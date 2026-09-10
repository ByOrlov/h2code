module H2code
  module Tools
    # TodoList — structured TODO list management tool.
    #
    # Contract ported from `packages/agent-core/src/tools/builtin/state/todo-list.ts`:
    #
    #   * Status: `pending` | `in_progress` | `done` (no `cancelled`).
    #   * Field: `title` (no `priority`, no `content`).
    #   * Markers: `[pending]` / `[in_progress]` / `[done]`.
    #   * Query mode: omit `todos` to read the current list without mutation.
    #   * Clear mode: pass `todos: []` to clear.
    #   * Write-reminder appended after every mutation.
    class TodoList < Tool
      # Verbatim of `todo-list-write-reminder.md`.
      TODO_LIST_WRITE_REMINDER =
        "Ensure that you continue to use the todo list to track progress. " \
        "Mark tasks done immediately after finishing them, and keep exactly " \
        "one task in_progress when work is underway."

      # Optional persistence location. When set (main agent), every mutation
      # is saved to `<session_dir>/todo.json` and reloaded on construction,
      # so todos survive a session restart / `--resume`. Subagents and ACP
      # keep the in-memory behavior (per-agent list, like JS).
      property session_dir : String? = nil

      getter todos : Array(TodoItem) = [] of TodoItem

      def initialize(@session_dir : String? = nil)
        load_persisted
      end

      def profiled_bytes : Int64
        @todos.sum(&.profiled_bytes)
      end

      def profiled_count : Int32
        @todos.size
      end

      def name : String
        Names::TODO_LIST
      end

      def description : String
        # Verbatim of `todo-list.md`.
        <<-TEXT
        Use this tool to maintain a structured TODO list as you work through a multi-step task. Use it proactively and often when progress tracking helps the current work. This is especially useful in long-running investigations and implementation tasks with several tool calls; in plan mode, write the plan to the plan file rather than tracking it here.

        **When to use:**
        - Multi-step tasks that span several tool calls
        - Tracking investigation progress across a large codebase search
        - Planning a sequence of edits before making them
        - After receiving new multi-step instructions, capture the requirements as todos
        - Before starting a tracked task, mark exactly one item as `in_progress`
        - Immediately after finishing a tracked task, mark it `done`; do not batch completions at the end

        **When NOT to use:**
        - Single-shot answers that complete in one or two tool calls
        - Trivial requests where tracking adds no clarity
        - Purely conversational or informational replies

        **Avoid churn:**
        - Do not re-call this tool when nothing meaningful has changed since the last call — update the list only after real progress.
        - When unsure of the current state, call query mode first (omit `todos`) to check the list before deciding what to update.
        - If no available tool can move any task forward, tell the user where you are stuck instead of repeatedly re-ordering the same todos.

        **How to use:**
        - Call with `todos: [...]` to replace the full list. Statuses: pending / in_progress / done.
        - Call with no `todos` argument to retrieve the current list without changing it.
        - Call with `todos: []` to clear the list.
        - Keep titles short and actionable (e.g. "Read session-control.ts", "Add planMode flag to TurnManager").
        - Update statuses as you make progress.
        - When work is underway, keep exactly one task `in_progress`.
        - Only mark a task `done` when it is fully accomplished.
        - Never mark a task `done` if tests are failing, implementation is partial, unresolved errors remain, or required files/dependencies could not be found.
        - If you encounter a blocker, keep the blocked task `in_progress` or add a new pending task describing what must be resolved.
        TEXT
      end

      def parameters : JSON::Any
        JSON.parse(%q({
          "type": "object",
          "properties": {
            "todos": {
              "type": "array",
              "items": {
                "type": "object",
                "properties": {
                  "title": {
                    "type": "string",
                    "description": "Short, actionable title for the todo."
                  },
                  "status": {
                    "type": "string",
                    "enum": ["pending", "in_progress", "done"],
                    "description": "Current status of the todo."
                  }
                },
                "required": ["title", "status"]
              },
              "description": "The updated todo list. Omit to read the current todo list without making changes. Pass an empty array to clear the list."
            }
          }
        }))
      end

      def execute(input : JSON::Any) : ToolResult
        todos_input = input["todos"]?

        # Query mode — return the current list without mutation.
        if todos_input.nil?
          return ToolResult.success(format_todos)
        end

        @todos.clear
        todos_input.as_a.each do |item|
          @todos << TodoItem.new(
            title: item["title"]?.try(&.to_s) || "",
            status: parse_status(item["status"]?.try(&.to_s) || "pending"),
          )
        end
        persist

        if @todos.empty?
          ToolResult.success("Todo list cleared.")
        else
          ToolResult.success("#{format_todos}\n\n#{TODO_LIST_WRITE_REMINDER}")
        end
      end

      # Clear the list and persist the empty state. Unlike mutating `#todos`
      # directly, this keeps `<session_dir>/todo.json` in sync, so a cleared
      # list stays cleared across a restart / `--resume`.
      def clear! : Nil
        @todos.clear
        persist
      end

      # ------------------------------------------------------------------
      # Persistence (<session_dir>/todo.json)
      # ------------------------------------------------------------------

      # Reload the persisted list (called on construction and available for
      # the wiring code after `session_dir` is injected). A corrupt file is
      # ignored — the session starts with an empty list instead of crashing.
      def load_persisted : Nil
        path = persist_path
        return if path.nil? || !File.exists?(path)
        parsed = JSON.parse(File.read(path))
        @todos.clear
        parsed.as_a.each do |item|
          @todos << TodoItem.new(
            title: item["title"]?.try(&.to_s) || "",
            status: parse_status(item["status"]?.try(&.to_s) || "pending"),
          )
        end
      rescue JSON::ParseException
        @todos.clear
      rescue IO::Error
        # Unreadable file — keep the current (empty) list.
      end

      private def persist : Nil
        path = persist_path
        return if path.nil?
        json = JSON.build do |j|
          j.array do
            @todos.each do |t|
              j.object do
                j.field "title", t.title
                j.field "status", status_to_s(t.status)
              end
            end
          end
        end
        File.write(path, json)
      end

      private def persist_path : String?
        dir = @session_dir
        dir.nil? ? nil : File.join(dir, "todo.json")
      end

      def format_todos : String
        return "Todo list is empty." if @todos.empty?

        lines = @todos.map do |t|
          "  #{status_marker(t.status)} #{t.title}"
        end
        "Current todo list:\n#{lines.join('\n')}"
      end

      # Number of items that still need work — anything not marked done.
      # Used by the agent loop to decide whether to inject a step reminder.
      def pending_count : Int32
        @todos.count { |t| !t.status.done? }
      end

      private def status_marker(status : TodoStatus) : String
        case status
        when .pending?     then "[pending]"
        when .in_progress? then "[in_progress]"
        when .done?        then "[done]"
        else                    "[pending]"
        end
      end

      private def parse_status(s : String) : TodoStatus
        case s.downcase
        when "in_progress" then TodoStatus::InProgress
        when "done"        then TodoStatus::Done
          # Backwards compat: accept the old Crystal "completed" value.
        when "completed" then TodoStatus::Done
        else                  TodoStatus::Pending
        end
      end

      private def status_to_s(status : TodoStatus) : String
        case status
        when .in_progress? then "in_progress"
        when .done?        then "done"
        else                    "pending"
        end
      end
    end

    enum TodoStatus
      Pending
      InProgress
      Done
    end

    struct TodoItem
      property title : String
      property status : TodoStatus

      def initialize(@title : String, @status : TodoStatus)
      end

      def profiled_bytes : Int64
        @title.profiled_bytes
      end
    end
  end
end
