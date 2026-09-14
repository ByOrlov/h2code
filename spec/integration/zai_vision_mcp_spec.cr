# Integration: the native Z.AI Vision port (Tools::ZaiVision — the Crystal
# port of the official `@z_ai/mcp-server` Vision MCP) end-to-end against the
# real Z.AI API. Mirrors the npm server's documented best practice: the image
# lives in a local directory and is passed by path, so it is inlined as a
# base64 data URL and analysed by the vision model.
#
# Gated behind H2CODE_ZAI_VISION_INTEGRATION=1 (`rake integration:zai_vision_mcp`)
# — the normal suite stays offline. Also skipped when the Z.AI key is not
# configured (ZAI_API_KEY / ZHIPU_API_KEY env or [provider.zai] in the config
# file) or ImageMagick is unavailable.
require "../spec_helper"

private TEXT = "Hello, please calculate 40 plus 2"

private def zai_api_key : String
  H2code::Config::Config.load.zai_api_key
rescue
  ENV["ZAI_API_KEY"]? || ENV["ZHIPU_API_KEY"]? || ""
end

private def imagemagick_binary : String?
  %w[magick convert].find do |b|
    Process.run(b, {"-version"},
      output: Process::Redirect::Close,
      error: Process::Redirect::Close).success?
  end
end

if ENV["H2CODE_ZAI_VISION_INTEGRATION"]? == "1"
  describe "ZaiVision MCP integration" do
    it "reads an English question from an image and answers it" do
      key = zai_api_key
      fail "no Z.AI API key configured (ZAI_API_KEY / ZHIPU_API_KEY / config)" if key.empty?

      bin = imagemagick_binary
      fail "ImageMagick (magick/convert) not found" unless bin

      # Render the question into a PNG, same recipe as the `rake mock:image`
      # task — a real model can read the words back.
      img = File.expand_path("tmp/zai_vision_integration.png", Dir.current)
      Dir.mkdir_p(File.dirname(img))
      system(bin, {"-size", "800x300", "xc:white", "-fill", "black",
                   "-pointsize", "48", "-gravity", "center", "-annotate", "+0+0", TEXT, img}).should be_true
      File.exists?(img).should be_true

      begin
        # Same wiring as the registration sites: the Coding Plan key routes
        # vision calls through the coding endpoint.
        H2code::Tools::ZaiVision::Tool.service = H2code::Tools::ZaiVision::Service
          .for_provider("zai-coding-plan", key)
        tool = H2code::Tools::ZaiVision::Tool.all
          .find! { |t| t.name == H2code::Tools::Names::ANALYZE_IMAGE }

        result = tool.execute(JSON.parse({
          "image_source" => img,
          "prompt"       => "Read the text in the image and follow its instruction. " \
                      "Reply with just the numeric answer.",
        }.to_json))

        # The image asks "40 plus 2" — accept the model's answer to the
        # question from the picture.
        if result.is_error? || !result.content.includes?("42")
          fail "expected the model to answer 42, got (is_error=#{result.is_error?}): #{result.content}"
        end
        result.content.should_not be_empty
      ensure
        H2code::Tools::ZaiVision::Tool.service = nil
        File.delete(img) rescue nil
      end
    end
  end
else
  puts "skipping ZaiVision MCP integration spec (set H2CODE_ZAI_VISION_INTEGRATION=1, e.g. `rake integration:zai_vision_mcp`)"
end
