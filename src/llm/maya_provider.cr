module H2code
  module LLM
    # Maya backend (https://github.com/mw00/project-maya) over the OpenAI Chat
    # Completions protocol. Maya's server keeps the same `strata --serve`
    # engine resident and exposes the same surface as Strata: one loaded model
    # (any model name is accepted, `/v1/models` lists the real one), GET
    # /health `max_context`, optional `--api-key`, a 400 instead of
    # truncation on overflow. So it is StrataProvider under another name —
    # only the overflow error's wording differs.
    class MayaProvider < StrataProvider
      DEFAULT_MODEL    = "default"
      DEFAULT_ENDPOINT = "http://127.0.0.1:8080/v1"

      # Maya keeps this many tokens of a request's prompt out of the room it
      # grants a completion (`max_context - CTX_SLACK - prompt`).
      CONTEXT_SLACK = 8

      def name : String
        "maya"
      end

      # Maya's overflow 400 uses OpenAI's wording ("maximum context length is
      # N tokens; prompt (P tokens) + max tokens (M) exceeds the context") and
      # names no allowed budget, so it is derived: N - P - the engine's slack.
      private def parse_context_budget(message : String?) : Int32?
        return nil unless message
        if md = message.match(/maximum context length is (\d+) tokens; prompt \((\d+) tokens\)/)
          budget = md[1].to_i - md[2].to_i - CONTEXT_SLACK
          return budget if budget > 0
        end
        nil
      end
    end

    Provider.register("maya", "Maya — local models on your GPU, no API key",
      label: "Local — Maya", needs_key: false,
      default_endpoint: MayaProvider::DEFAULT_ENDPOINT,
      default_model: MayaProvider::DEFAULT_MODEL,
      key_hint: "Only needed if Maya runs with --api-key") do |config, _|
      MayaProvider.new(
        model: config.maya_model || MayaProvider::DEFAULT_MODEL,
        endpoint: config.maya_endpoint || MayaProvider::DEFAULT_ENDPOINT,
        api_key: config.maya_api_key,
      )
    end
  end
end
