module H2code
  module Prompt
    class AgentsMd
      def self.discover(cwd : String) : String
        home = HomePort.home
        h2code_home = ENV["H2CODE_HOME"]? || File.join(home, ".h2code")

        paths = [] of String

        user_agents = File.join(h2code_home, "AGENTS.md")
        paths << user_agents if File.exists?(user_agents)

        user_agents2 = File.join(home, ".agents", "AGENTS.md")
        paths << user_agents2 if File.exists?(user_agents2)

        # Cascade: collect AGENTS.md from the chain of directories between the
        # project root and cwd (inclusive at both ends), mirroring kimi-code's
        # `dirsRootToLeaf`. Point checks only — no recursive glob, which would
        # stat every file under the repo (including `.git/objects`).
        project_root = find_git_root(cwd) || cwd
        dirs = [] of String
        cur = File.expand_path(cwd)
        loop do
          dirs << cur
          break if cur == project_root
          parent = File.dirname(cur)
          break if parent == cur
          cur = parent
        end
        dirs.reverse! # root → leaf

        dirs.each do |dir|
          brand = File.join(dir, ".h2code", "AGENTS.md")
          paths << brand if File.exists?(brand) && !paths.includes?(brand)
          generic = File.join(dir, "AGENTS.md")
          paths << generic if File.exists?(generic) && !paths.includes?(generic)
        end

        paths.sort_by! { |p| p.size }

        return "" if paths.empty?

        sections = [] of String
        paths.each do |p|
          content = File.read(p).strip
          next if content.empty?
          rel = relative_to(p, cwd)
          sections << "<!-- From: #{rel} -->\n#{content}"
        end

        result = sections.join("\n\n")

        if result.bytesize > 32_768
          STDERR.puts "Warning: AGENTS.md content is large (#{result.bytesize} bytes)"
        end

        result
      end

      private def self.find_git_root(cwd : String) : String?
        current = cwd
        loop do
          if Dir.exists?(File.join(current, ".git"))
            return current
          end
          parent = File.dirname(current)
          break if parent == current
          current = parent
        end
        nil
      end

      private def self.relative_to(path : String, base : String) : String
        if path.starts_with?(base)
          rel = path[base.size..]
          rel.lchop('/')
        else
          path
        end
      end
    end
  end
end
