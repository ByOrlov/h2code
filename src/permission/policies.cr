module H2code
  module Permission
    # Rule-based permission policies — a user-configurable allow/deny/ask
    # rule set that gates tool calls before the interactive approval prompt.
    #
    # Rules use a small DSL, mirroring the TS `matches-rule.ts` parser:
    #
    #   Tools::Names::WRITE              → matches any Write call (tool-name only)
    #   "Read(/etc/**)"      → Read on paths under /etc
    #   "Bash(rm *)"         → Bash commands starting with "rm"
    #   "mcp__github__*"     → glob on the tool name itself
    #
    # The first matching rule wins; deny rules always fire regardless of
    # permission mode (manual / auto / yolo). With no match the caller
    # falls through to the mode-dependent default (ask in manual, approve
    # in auto / yolo).
    #
    # Ref: `packages/agent-core/src/agent/permission/matches-rule.ts`,
    #      `packages/agent-core/src/agent/permission/types.ts`.
    module Policies
      enum Decision
        Allow
        Deny
        Ask

        def to_s : String
          case self
          in Allow then "allow"
          in Deny  then "deny"
          in Ask   then "ask"
          end
        end

        def self.parse(str : String) : Decision?
          case str.downcase
          when "allow" then Allow
          when "deny"  then Deny
          when "ask"   then Ask
          else              nil
          end
        end
      end

      enum Scope
        # Statically loaded from user / project config.
        User
        Project
        # Produced at runtime by "approve for session".
        SessionRuntime
        # Per-turn override (e.g. injected by a hook for this turn only).
        TurnOverride

        def to_s : String
          case self
          in User           then "user"
          in Project        then "project"
          in SessionRuntime then "session-runtime"
          in TurnOverride   then "turn-override"
          end
        end

        def self.parse(str : String) : Scope
          case str.downcase
          when "user"            then User
          when "project"         then Project
          when "session-runtime" then SessionRuntime
          when "turn-override"   then TurnOverride
          else                        User
          end
        end
      end

      struct Rule
        property decision : Decision
        property pattern : String
        property scope : Scope = Scope::User
        property reason : String?

        def initialize(@decision : Decision, @pattern : String,
                       @scope : Scope = Scope::User, @reason : String? = nil)
        end

        # Parse a rule pattern into its tool-name + optional arg-pattern
        # components. `Bash(rm *)` → {Tools::Names::BASH, "rm *"}, `Write` → {Tools::Names::WRITE, nil}.
        # Returns nil on a malformed pattern (missing close paren, empty name).
        def parsed : NamedTuple(tool: String, args: String?)?
          Policies.parse_pattern(@pattern)
        end
      end

      # Parse a DSL pattern string into a tool name and optional argument
      # pattern. Returns nil on malformed input rather than throwing, so a
      # bad rule in user config never crashes the agent loop.
      def self.parse_pattern(pattern : String) : NamedTuple(tool: String, args: String?)?
        trimmed = pattern.strip
        return nil if trimmed.empty?

        open_idx = trimmed.index('(')
        return {tool: trimmed, args: nil} if open_idx.nil?

        return nil unless trimmed.ends_with?(')')
        tool = trimmed[0...open_idx]
        arg_pattern = trimmed[(open_idx + 1)...-1]
        return nil if tool.empty?
        # `Tool()` parses to no arg pattern so it stays tool-name-only.
        return {tool: tool, args: nil} if arg_pattern.empty?
        {tool: tool, args: arg_pattern}
      end

      # Picomatch-style glob match. Unlike shell glob, `*` matches across
      # path separators (`/`) so command patterns like `rm *` work as
      # expected. `?` matches a single character, `**` is treated the same
      # as `*` for our purposes.
      def self.glob_match?(value : String, pattern : String) : Bool
        return value == pattern if pattern.empty?
        regex = glob_to_regex(pattern)
        !!(regex =~ value)
      end

      # Match a rule against a tool call. Returns the matching rule's
      # decision context, or nil when the rule does not apply.
      def self.match?(rule : Rule, tool_name : String, args : String) : Bool
        parsed = rule.parsed
        return false unless parsed

        # Tool-name match (`*` matches any tool).
        unless parsed[:tool] == "*" || glob_match?(tool_name, parsed[:tool])
          return false
        end

        arg_pattern = parsed[:args]
        return true if arg_pattern.nil?

        # Argument match is tool-specific: Bash matches its `command`,
        # file tools match their path field, others fall back to a raw
        # match against the JSON args blob.
        subject = arg_subject(tool_name, args)
        match_args?(arg_pattern, subject)
      end

      # Pick the field to match the arg pattern against, based on the tool.
      private def self.arg_subject(tool_name : String, args : String) : String
        return args if args.empty?
        parsed = JSON.parse(args)
        case tool_name
        when Tools::Names::BASH
          parsed["command"]?.try(&.to_s) || args
        when Tools::Names::READ, Tools::Names::READ_MEDIA_FILE
          parsed["path"]?.try(&.to_s) || parsed["filePath"]?.try(&.to_s) || args
        when Tools::Names::WRITE, Tools::Names::EDIT
          parsed["filePath"]?.try(&.to_s) || args
        when Tools::Names::APPLY_PATCH
          patch_paths(parsed["input"]?.try(&.to_s) || parsed["patch"]?.try(&.to_s)) || args
        when Tools::Names::GLOB, Tools::Names::GREP
          parsed["pattern"]?.try(&.to_s) || parsed["path"]?.try(&.to_s) || args
        else
          args
        end
      rescue JSON::ParseException
        args
      end

      # Extract every file path mentioned in an ApplyPatch payload
      # (`*** Add/Update/Delete File: <path>`) so permission rules like
      # `ApplyPatch(src/*)` match per-path instead of against the raw blob.
      private def self.patch_paths(patch : String?) : String?
        return nil if patch.nil? || patch.empty?
        paths = [] of String
        patch.each_line do |line|
          if line.starts_with?("*** Add File: ") || line.starts_with?("*** Delete File: ") ||
             line.starts_with?("*** Update File: ") || line.starts_with?("*** Move to: ")
            paths << line.split(':', 2)[1].strip
          end
        end
        paths.empty? ? nil : paths.join(' ')
      end

      # Match an arg pattern against a subject string. Supports a leading
      # `!` for negation (`!rm *` = "everything except rm commands").
      private def self.match_args?(arg_pattern : String, subject : String) : Bool
        negated = arg_pattern.starts_with?('!')
        positive = negated ? arg_pattern[1..] : arg_pattern
        hit = glob_match?(subject, positive)
        negated ? !hit : hit
      end

      # Convert a glob pattern to a regex. `*` and `**` → `.*`, `?` → `.`,
      # everything else is escaped. Case-insensitive to match the TS
      # nocase default for command/path matching.
      private def self.glob_to_regex(pattern : String) : Regex
        sb = String::Builder.new("\\A")
        i = 0
        chars = pattern.chars
        while i < chars.size
          c = chars[i]
          case c
          when '*'
            # Collapse `**` into a single `.*` — both span the whole string.
            while i + 1 < chars.size && chars[i + 1] == '*'
              i += 1
            end
            sb << ".*"
          when '?'
            sb << "."
          else
            sb << Regex.escape(c.to_s)
          end
          i += 1
        end
        sb << "\\z"
        Regex.new(sb.to_s, Regex::Options::IGNORE_CASE)
      rescue Regex::Error
        # Fallback: exact match if the generated regex is invalid.
        Regex.new("\\A" + Regex.escape(pattern) + "\\z")
      end

      # An ordered set of permission rules. The first matching rule wins;
      # deny rules take precedence regardless of mode.
      class RuleSet
        getter rules : Array(Rule)

        def initialize(@rules : Array(Rule) = [] of Rule)
        end

        def <<(rule : Rule) : self
          @rules << rule
          self
        end

        def concat(rules : Array(Rule)) : self
          @rules.concat(rules)
          self
        end

        def clear : Nil
          @rules.clear
        end

        def empty? : Bool
          @rules.empty?
        end

        # Evaluate the rule set for a tool call. Returns the matching rule
        # (with its decision), or nil when nothing matches — the caller
        # then applies its mode-dependent default.
        def evaluate(tool_name : String, args : String) : Rule?
          @rules.each do |rule|
            return rule if Policies.match?(rule, tool_name, args)
          end
          nil
        end

        # Convenience: returns the decision for a tool call, or nil.
        def decision_for(tool_name : String, args : String) : {Decision, Rule}?
          rule = evaluate(tool_name, args)
          rule ? {rule.decision, rule} : nil
        end
      end
    end
  end
end
