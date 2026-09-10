require "./agent"
require "./abort"
require "../tools/agent"
require "../tools/agent_swarm"
require "../tools/registry"

module H2code
  module Loop
    # One tracked child agent. Mirrors the JS `IAgentScopeHandle` + subagent
    # metadata pair: the lifecycle registry owns *existence*, this struct owns
    # the parent ↔ child association and the per-agent run state.
    class SubagentEntry
      getter agent : Loop::Agent
      getter context : Context::Memory
      getter profile_name : String
      getter parent_agent_id : String
      getter agent_id : String
      property? running : Bool = false
      # Saved swarm item label, so a later `AgentSwarm(resume_agent_ids=...)`
      # can recover the item for the XML render (v1-parity).
      property swarm_item : String?

      def initialize(@agent : Loop::Agent,
                     @context : Context::Memory,
                     @profile_name : String,
                     @parent_agent_id : String,
                     @agent_id : String,
                     @swarm_item : String? = nil)
      end
    end

    # In-process registry of child agents. One instance per session (wired from
    # `CLI.run_interactive` / `CLI.run_headless`). Subagents survive across
    # turns within the same process so `Agent(resume: ...)` can pick up where a
    # prior run left off; they do not survive a process restart (the JS engine
    # persists subagent metadata to the session store — that is out of scope
    # here).
    class SubagentRegistry
      @entries = {} of String => SubagentEntry
      @counter = 0

      def initialize
      end

      # Spawn a fresh child agent bound to `profile_name`. The child shares the
      # parent's provider (same model) but gets an isolated `Context::Memory`
      # and a `Tools::Registry` restricted by the profile.
      def create(parent_agent : Loop::Agent,
                 profile_name : String,
                 work_dir : String,
                 system_prompt : String,
                 permission_mode : Permission::Mode,
                 max_context_tokens : Int32,
                 parent_agent_id : String,
                 swarm_item : String? = nil) : SubagentEntry
        @counter += 1
        agent_id = "agent-#{@counter}"

        tools = ProfileRegistry.build(profile_name, work_dir)
        permission = Permission::Manager.new(permission_mode)
        context = Context::Memory.new
        context.max_context_tokens = max_context_tokens

        # Children may themselves delegate, so their Agent/Swarm runners must
        # point back at this same registry. We pass a closure that wires them
        # up lazily — the tools are already constructed without a runner.
        child_agent = Loop::Agent.new(parent_agent.provider, context, tools, permission)

        entry = SubagentEntry.new(
          agent: child_agent,
          context: context,
          profile_name: profile_name,
          parent_agent_id: parent_agent_id,
          agent_id: agent_id,
          swarm_item: swarm_item,
        )
        @entries[agent_id] = entry
        entry
      end

      def get(agent_id : String) : SubagentEntry?
        @entries[agent_id]?
      end

      def running?(agent_id : String) : Bool
        entry = @entries[agent_id]?
        entry ? entry.running? : false
      end

      def owned_by?(agent_id : String, parent_agent_id : String) : Bool
        entry = @entries[agent_id]?
        entry ? (entry.parent_agent_id == parent_agent_id) : false
      end

      def swarm_item(agent_id : String) : String?
        @entries[agent_id]?.try(&.swarm_item)
      end

      def size : Int32
        @entries.size
      end
    end

    # Builds a `Tools::Registry` containing only the tools the named profile
    # allows. The profile's `tools` string (e.g. `"Read, Write, Bash, ..."`) is
    # parsed and each allowed tool is instantiated fresh — subagents must not
    # share mutable tool state (e.g. `TodoList` items, `Bash` working dir) with
    # the parent or with each other.
    #
    # `mcp__*` in the profile string is a wildcard for MCP tools; MCP is not
    # wired in this build, so the wildcard matches nothing and is silently
    # dropped.
    class ProfileRegistry
      def self.build(profile_name : String, work_dir : String) : Tools::Registry
        profile = Tools::Agent::PROFILES.find { |p| p.name == profile_name }
        raise "Unknown agent profile: #{profile_name}" unless profile

        allowed = parse_allowed(profile.tools)
        registry = Tools::Registry.new

        # work_dir-sensitive tools.
        registry.register(Tools::Bash.new(work_dir)) if allowed.includes?(Tools::Names::BASH)
        registry.register(Tools::Read.new(work_dir)) if allowed.includes?(Tools::Names::READ)
        registry.register(Tools::Write.new(work_dir)) if allowed.includes?(Tools::Names::WRITE)
        registry.register(Tools::Edit.new(work_dir)) if allowed.includes?(Tools::Names::EDIT)
        registry.register(Tools::ApplyPatchTool.new(work_dir)) if allowed.includes?(Tools::Names::APPLY_PATCH)
        registry.register(Tools::Glob.new(work_dir)) if allowed.includes?(Tools::Names::GLOB)
        registry.register(Tools::Grep.new(work_dir)) if allowed.includes?(Tools::Names::GREP)

        # stateless tools.
        registry.register(Tools::TodoList.new) if allowed.includes?(Tools::Names::TODO_LIST)
        registry.register(Tools::AgentSwarm.new) if allowed.includes?(Tools::Names::AGENT_SWARM)
        registry.register(Tools::Agent.new) if allowed.includes?(Tools::Names::AGENT)
        registry.register(Tools::AskUserQuestion.new) if allowed.includes?(Tools::Names::ASK_USER_QUESTION)
        registry.register(Tools::FetchURL.new) if allowed.includes?(Tools::Names::FETCH_URL)
        registry.register(Tools::WebSearch.new) if allowed.includes?(Tools::Names::WEB_SEARCH)
        registry.register(Tools::Skill.new) if allowed.includes?(Tools::Names::SKILL)
        registry.register(Tools::EnterPlanMode.new) if allowed.includes?(Tools::Names::ENTER_PLAN_MODE)
        registry.register(Tools::ExitPlanMode.new) if allowed.includes?(Tools::Names::EXIT_PLAN_MODE)
        registry.register(Tools::CreateGoal.new) if allowed.includes?(Tools::Names::CREATE_GOAL)
        registry.register(Tools::GetGoal.new) if allowed.includes?(Tools::Names::GET_GOAL)
        registry.register(Tools::UpdateGoal.new) if allowed.includes?(Tools::Names::UPDATE_GOAL)
        registry.register(Tools::SetGoalBudget.new) if allowed.includes?(Tools::Names::SET_GOAL_BUDGET)
        registry.register(Tools::TaskList.new) if allowed.includes?(Tools::Names::TASK_LIST)
        registry.register(Tools::TaskOutput.new) if allowed.includes?(Tools::Names::TASK_OUTPUT)
        registry.register(Tools::TaskStop.new) if allowed.includes?(Tools::Names::TASK_STOP)
        registry.register(Tools::CronCreate.new) if allowed.includes?(Tools::Names::CRON_CREATE)
        registry.register(Tools::CronList.new) if allowed.includes?(Tools::Names::CRON_LIST)
        registry.register(Tools::CronDelete.new) if allowed.includes?(Tools::Names::CRON_DELETE)
        registry.register(Tools::ReadMediaFile.new) if allowed.includes?(Tools::Names::READ_MEDIA_FILE)
        registry.register(Tools::SelectTools.new) if allowed.includes?("SelectTools") && Tools::ToolSelect.service.try(&.enabled?)

        registry
      end

      # Parse `"Read, Write, Grep, ..."` into a Set of tool names. `mcp__*` and
      # other wildcards are dropped (no MCP tools in this build).
      private def self.parse_allowed(tools_string : String) : Set(String)
        set = Set(String).new
        tools_string.split(',').each do |raw|
          name = raw.strip
          next if name.empty?
          next if name.includes?('*') # mcp__* and friends
          set << name
        end
        set
      end
    end
  end
end
