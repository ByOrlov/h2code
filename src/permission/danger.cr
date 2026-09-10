module H2code
  module Permission
    # Danger detection for tool arguments. Returns a short human-readable
    # label when a tool call matches a known-dangerous pattern (recursive
    # delete, elevated privileges, pipe-to-shell, raw device writes, etc.).
    #
    # The label is surfaced in the approval panel in bold red so the user
    # knows the command is risky before approving it.
    #
    # Ref: `apps/kimi-code/src/tui/reverse-rpc/approval/adapter.ts` (DANGER_PATTERNS).
    module Danger
      struct Pattern
        getter regex : Regex
        getter label : String

        def initialize(@regex : Regex, @label : String)
        end
      end

      # Order matters: the first match wins, so the most severe / specific
      # patterns are listed first.
      PATTERNS = [
        Pattern.new(Regex.new("\\brm\\s+(-[a-zA-Z]*[rRfF][a-zA-Z]*|--recursive|--force)", Regex::Options::IGNORE_CASE), "recursive delete"),
        # cmd/PowerShell recursive deletes: `rd /s /q`, `Remove-Item -Recurse`.
        Pattern.new(Regex.new("\\b(rd|rmdir|Remove-Item)\\b[^|]*(-Recurse|/[sS]\\b)", Regex::Options::IGNORE_CASE), "recursive delete"),
        Pattern.new(Regex.new("\\bsudo\\b", Regex::Options::IGNORE_CASE), "elevated privileges"),
        # Windows elevation vectors: runas, PowerShell Start-Process -Verb RunAs.
        Pattern.new(Regex.new("(\\brunas\\b|-Verb\\s+RunAs)", Regex::Options::IGNORE_CASE), "elevated privileges"),
        # Destructive git: these rewrite shared history (refs, reflog,
        # objects) and can poison the repository or other branches — the
        # fork sandbox isolates its own clone, but the main checkout is
        # still reachable from bash, so surface these loudly.
        # `git push --force/-f` or a forced refspec (`+branch:branch`).
        Pattern.new(Regex.new("\\bgit\\b[^|;]*\\bpush\\b[^|;]*(\\s--force\\b|\\s-f\\b|\\s\\+[\\w./-]+:)", Regex::Options::IGNORE_CASE), "force push"),
        # `git push --delete/-d` removes a remote branch.
        Pattern.new(Regex.new("\\bgit\\b[^|;]*\\bpush\\b[^|;]*\\s(-d|--delete)\\b", Regex::Options::IGNORE_CASE), "remote branch delete"),
        # `git branch -D` (or --delete --force) drops a local branch.
        # Case-sensitive on purpose: `-d` (delete-only-if-merged) is safe,
        # `-D` (force) is not, and IGNORE_CASE would conflate them.
        Pattern.new(Regex.new("\\bgit\\b[^|;]*\\sbranch\\b[^|;]*\\s(-D\\b|--delete\\b[^|;]*--force|--force\\b[^|;]*--delete)"), "branch delete"),
        # `git reflog expire` destroys the recovery history for refs.
        Pattern.new(Regex.new("\\bgit\\b[^|;]*\\breflog\\b[^|;]*\\bexpire\\b", Regex::Options::IGNORE_CASE), "reflog wipe"),
        # `git gc --prune` / `git prune` can drop unreachable objects.
        Pattern.new(Regex.new("\\bgit\\s+(gc\\b[^|;]*--prune|prune\\b)", Regex::Options::IGNORE_CASE), "object prune"),
        # `git update-ref` rewrites refs directly, bypassing safety checks.
        Pattern.new(Regex.new("\\bgit\\s+update-ref\\b", Regex::Options::IGNORE_CASE), "ref rewrite"),
        Pattern.new(Regex.new("\\b(curl|wget)\\b[^|]*\\|\\s*(sh|bash|zsh)\\b", Regex::Options::IGNORE_CASE), "pipe to shell"),
        # PowerShell download cradles — iex wrapping a download, or a
        # downloaded script piped into iex.
        Pattern.new(Regex.new("\\b(iex|Invoke-Expression)\\b[^|]*\\b(irm|iwr|Invoke-RestMethod|Invoke-WebRequest)\\b|\\b(irm|iwr)\\b[^|]*\\|\\s*(iex|Invoke-Expression)\\b", Regex::Options::IGNORE_CASE), "pipe to shell"),
        Pattern.new(Regex.new("\\bdd\\b[^|]*\\bof=", Regex::Options::IGNORE_CASE), "raw device write"),
        Pattern.new(Regex.new("\\bmkfs\\b", Regex::Options::IGNORE_CASE), "filesystem format"),
        # Windows format: `format C:`, `format /FS:NTFS D:` (flags optional).
        Pattern.new(Regex.new("\\bformat\\s+(/[a-zA-Z]+[a-zA-Z:]*\\s+)*[a-zA-Z]:", Regex::Options::IGNORE_CASE), "filesystem format"),
        # diskpart can `clean` (erase) whole disks.
        Pattern.new(Regex.new("\\bdiskpart\\b", Regex::Options::IGNORE_CASE), "disk partitioning tool"),
        Pattern.new(Regex.new(">\\s*/dev/(sd|nvme|disk|hd)", Regex::Options::IGNORE_CASE), "write to raw device"),
        # Windows device-namespace access: \\.\PhysicalDrive0, \\.\C:,
        # \\.\Volume{...} — direct raw-device I/O. %r literal: the
        # backslash-heavy regex is unreadable as an escaped string.
        Pattern.new(%r{\\\\\.\\(PhysicalDrive|CdRom|Tape|Volume|[a-zA-Z]:)}i, "write to raw device"),
        # Deleting Volume Shadow Copies wipes restore points (ransomware staple).
        Pattern.new(Regex.new("\\bvssadmin\\b[^|]*\\bdelete\\b[^|]*\\bshadows\\b", Regex::Options::IGNORE_CASE), "delete shadow copies"),
        Pattern.new(Regex.new("\\bchmod\\s+-R?\\s*777\\b", Regex::Options::IGNORE_CASE), "world-writable"),
        Pattern.new(Regex.new(":\\(\\)\\s*\\{\\s*:\\|:&\\s*\\}", Regex::Options::IGNORE_CASE), "fork bomb"),
      ] of Pattern

      # Returns the danger label for a Bash command, or nil if the command
      # is not considered dangerous.
      def self.detect_command(command : String) : String?
        PATTERNS.each do |p|
          return p.label if command =~ p.regex
        end
        nil
      end

      # Inspect a tool call's arguments and return a danger label, or nil.
      # Only Bash is analysed today; file tools are not dangerous by
      # themselves (the approval flow still gates them).
      def self.detect(tool_name : String, args : String) : String?
        return nil unless tool_name == Tools::Names::BASH
        command = extract_command(args) || args
        detect_command(command)
      end

      # Convenience overload for pre-parsed arguments.
      def self.detect(tool_name : String, args : JSON::Any) : String?
        return nil unless tool_name == Tools::Names::BASH
        command = args["command"]?.try(&.to_s) || args.to_s
        detect_command(command)
      end

      private def self.extract_command(args : String) : String?
        return nil if args.empty?
        parsed = JSON.parse(args)
        parsed["command"]?.try(&.to_s)
      rescue JSON::ParseException
        nil
      end
    end
  end
end
