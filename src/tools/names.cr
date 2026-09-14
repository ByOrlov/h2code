module H2code
  module Tools
    # Single source of truth for the public names of built-in tools.
    #
    # Tool names are matched against in dozens of places (permission rules,
    # dedup tracking, subagent tool whitelists, the TUI message renderer,
    # profiled memory, hooks). A typo in any of those scattered string
    # literals silently breaks matching. Every tool that is part of the
    # built-in registry exposes its name through `Tool#name`, and that method
    # returns one of these constants; consumers compare against the same
    # constants so a mismatch is a compile-time error rather than a silent
    # match failure.
    #
    # The `select_tools` loader is intentionally lowercase to mirror the
    # progressive-disclosure sentinel used elsewhere; everything else is
    # PascalCase.
    module Names
      BASH                  = "Bash"
      READ                  = "Read"
      WRITE                 = "Write"
      EDIT                  = "Edit"
      GLOB                  = "Glob"
      GREP                  = "Grep"
      TODO_LIST             = "TodoList"
      AGENT                 = "Agent"
      AGENT_SWARM           = "AgentSwarm"
      ASK_USER_QUESTION     = "AskUserQuestion"
      FETCH_URL             = "FetchURL"
      READ_MEDIA_FILE       = "ReadMediaFile"
      WEB_SEARCH            = "WebSearch"
      SKILL                 = "Skill"
      SELECT_TOOLS          = "select_tools"
      ENTER_PLAN_MODE       = "EnterPlanMode"
      EXIT_PLAN_MODE        = "ExitPlanMode"
      CREATE_GOAL           = "CreateGoal"
      GET_GOAL              = "GetGoal"
      UPDATE_GOAL           = "UpdateGoal"
      SET_GOAL_BUDGET       = "SetGoalBudget"
      TASK_LIST             = "TaskList"
      TASK_OUTPUT           = "TaskOutput"
      TASK_STOP             = "TaskStop"
      CRON_CREATE           = "CronCreate"
      CRON_LIST             = "CronList"
      CRON_DELETE           = "CronDelete"
      WAIT_FOR_CI           = "WaitForCI"
      MERGE_REQUEST         = "MergeRequest"
      CURRENT_TIME          = "CurrentTime"
      GET_CONTEXT_REMAINING = "GetContextRemaining"
      APPLY_PATCH           = "ApplyPatch"
      INTERACTIVE_SHELL     = "InteractiveShell"
      # Z.AI Vision tools (native port of the official `@z_ai/mcp-server`
      # Vision MCP; registered only for Z.AI providers with a configured key).
      UI_TO_ARTIFACT               = "UiToArtifact"
      EXTRACT_TEXT_FROM_SCREENSHOT = "ExtractTextFromScreenshot"
      DIAGNOSE_ERROR_SCREENSHOT    = "DiagnoseErrorScreenshot"
      UNDERSTAND_TECHNICAL_DIAGRAM = "UnderstandTechnicalDiagram"
      ANALYZE_DATA_VISUALIZATION   = "AnalyzeDataVisualization"
      UI_DIFF_CHECK                = "UiDiffCheck"
      ANALYZE_IMAGE                = "AnalyzeImage"
      ANALYZE_VIDEO                = "AnalyzeVideo"
    end
  end
end
