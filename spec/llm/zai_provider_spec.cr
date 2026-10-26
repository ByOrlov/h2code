require "../spec_helper"
require "../../src/llm/zai_provider"
require "../../src/llm/moonshot_provider"

describe H2code::LLM::ZaiProvider do
  describe "#default_context_tokens" do
    it "gives GLM-5.2 and newer the 1M window" do
      {"glm-5.2", "GLM-5.3", "glm-6"}.each do |model|
        provider = H2code::LLM::ZaiProvider.new(model: model, api_key: "k")
        provider.default_context_tokens.should eq(H2code::LLM::ZaiProvider::CONTEXT_TOKENS_1M)
      end
    end

    it "gives the 4.x/5.0/5.1 generation the 200K window" do
      {"glm-4.6", "glm-4.7", "glm-5", "glm-5.1"}.each do |model|
        provider = H2code::LLM::ZaiProvider.new(model: model, api_key: "k")
        provider.default_context_tokens.should eq(H2code::LLM::ZaiProvider::CONTEXT_TOKENS_200K)
      end
    end

    it "honors the 1m name marker regardless of generation" do
      provider = H2code::LLM::ZaiProvider.new(model: "glm-4.6-1m", api_key: "k")
      provider.default_context_tokens.should eq(H2code::LLM::ZaiProvider::CONTEXT_TOKENS_1M)
    end

    it "returns nil for unknown model names" do
      provider = H2code::LLM::ZaiProvider.new(model: "custom-finetune", api_key: "k")
      provider.default_context_tokens.should be_nil
    end
  end

  describe "Provider.resolve_context_window" do
    it "replaces the global default with the model's real window" do
      provider = H2code::LLM::ZaiProvider.new(model: "glm-5.2", api_key: "k")
      H2code::LLM::Provider.resolve_context_window(provider, 262_144, false)
        .should eq(H2code::LLM::ZaiProvider::CONTEXT_TOKENS_1M)
    end

    it "keeps an explicitly configured window" do
      provider = H2code::LLM::ZaiProvider.new(model: "glm-5.2", api_key: "k")
      H2code::LLM::Provider.resolve_context_window(provider, 150_000, true)
        .should eq(150_000)
    end

    it "falls back to the configured window for providers without a default" do
      provider = H2code::LLM::MoonshotProvider.new(model: "kimi-for-coding", api_key: "k")
      H2code::LLM::Provider.resolve_context_window(provider, 262_144, false)
        .should eq(262_144)
    end
  end
end
