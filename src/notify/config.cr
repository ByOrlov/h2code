module H2code
  module Notify
    # Configuration for the notification subsystem, mirroring the `[notifications]`
    # TOML block. See plans/PLAN.md §Config for the schema.
    class Config
      property? enabled : Bool = true
      property condition : String = "unfocused" # "unfocused" | "always" (terminal channel only)

      property? sound_enabled : Bool = false
      property sound_volume : Int32 = 70 # 0–100
      property sound_done : String = ""
      property sound_input_required : String = ""
      property sound_working : String = ""

      property? terminal_enabled : Bool = true

      property? webhook_enabled : Bool = false
      property webhook_url : String = ""
      property webhook_method : String = "POST"
      property webhook_timeout_ms : Int32 = 5000
      property webhook_secret : String = ""
      property webhook_headers : Hash(String, String) = {} of String => String

      def initialize
      end

      def self.default : Config
        new
      end
    end
  end
end
