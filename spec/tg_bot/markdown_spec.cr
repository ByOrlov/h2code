require "../spec_helper"
require "../../src/tg_bot/markdown"

describe TgBot::MarkdownV2 do
  it "escapes specials in plain text" do
    TgBot::MarkdownV2.convert("Hello. World! (a) [b] {c}").should eq(
      "Hello\\. World\\! \\(a\\) \\[b\\] \\{c\\}")
  end

  it "converts bold and italic" do
    TgBot::MarkdownV2.convert("a **b** and *c*").should eq("a *b* and _c_")
  end

  it "keeps inline code content verbatim" do
    TgBot::MarkdownV2.convert("run `ls -la` ok").should eq("run `ls -la` ok")
  end

  it "does not italicize across word chars" do
    TgBot::MarkdownV2.convert("foo_bar_baz").should eq("foo\\_bar\\_baz")
  end

  it "passes code fences through" do
    TgBot::MarkdownV2.convert("```crystal\nputs 1 + 2\n```").should eq(
      "```crystal\nputs 1 + 2\n```")
  end

  it "closes a fence clipped by the size limit" do
    TgBot::MarkdownV2.convert("```crystal\nputs 1").should eq(
      "```crystal\nputs 1\n```")
  end

  it "converts headings to bold lines" do
    TgBot::MarkdownV2.convert("# Title.").should eq("*Title\\.*")
  end

  it "converts bullets and ordered items" do
    TgBot::MarkdownV2.convert("- foo.bar\n2) baz").should eq(
      "• foo\\.bar\n2\\. baz")
  end

  it "keeps links" do
    TgBot::MarkdownV2.convert("see [docs](https://example.com/a)").should eq(
      "see [docs](https://example.com/a)")
  end

  it "converts strikethrough" do
    TgBot::MarkdownV2.convert("~~gone~~").should eq("~gone~")
  end

  it "wraps tables into a pre block" do
    TgBot::MarkdownV2.convert("| a | b |\n|---|---|\n| 1 | 2 |").should eq(
      "```\n| a | b |\n|---|---|\n| 1 | 2 |\n```")
  end

  it "renders horizontal rules without escaping noise" do
    TgBot::MarkdownV2.convert("intro\n\n---\n\noutro").should eq(
      "intro\n\n───\n\noutro")
  end
end
