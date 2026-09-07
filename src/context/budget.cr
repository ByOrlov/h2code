module H2code
  module Context
    class Budget
      MAX_RESULT_CHARS = 50_000
      PREVIEW_CHARS    =  2_000
      OUTPUT_DIR       = File.join(HomePort.home, ".h2code", "tool-results")

      def self.budget(tool_name : String, tool_call_id : String, content : String) : {String, Bool}
        return {content, false} if content.size <= MAX_RESULT_CHARS

        Dir.mkdir_p(OUTPUT_DIR)

        uuid = Random::Secure.hex(8)
        file_name = "#{tool_name}-#{tool_call_id}-#{uuid}.txt"
        file_path = File.join(OUTPUT_DIR, file_name)

        File.write(file_path, content)

        preview = content[0...PREVIEW_CHARS]
        truncated = "[Output truncated. #{content.size} chars total. "
        truncated += "Full output saved to: #{file_path}. "
        truncated += "Use the Read tool with path=\"#{file_path}\" to view full output.]\n\n"
        truncated += preview

        {truncated, true}
      end
    end
  end
end
