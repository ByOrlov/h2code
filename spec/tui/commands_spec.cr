require "../spec_helper"

describe H2code::TUI::CommandRegistry do
  describe ".parse" do
    it "parses command without args" do
      result = H2code::TUI::CommandRegistry.parse("/help")
      result.should_not be_nil
      if r = result
        r.command.should eq("/help")
        r.args.should eq("")
      end
    end

    it "parses command with args" do
      result = H2code::TUI::CommandRegistry.parse("/add-dir /tmp/foo")
      result.should_not be_nil
      if r = result
        r.command.should eq("/add-dir")
        r.args.should eq("/tmp/foo")
      end
    end

    it "returns nil for non-command input" do
      result = H2code::TUI::CommandRegistry.parse("hello world")
      result.should be_nil
    end
  end

  describe ".match" do
    it "matches commands by prefix" do
      matches = H2code::TUI::CommandRegistry.match("/c")
      matches.map(&.name).should contain("/clear")
      matches.map(&.name).should contain("/compact")
    end

    it "offers /ci type alongside /ci while typing" do
      matches = H2code::TUI::CommandRegistry.match("/ci").map(&.name)
      matches.should contain("/ci")
      matches.should contain("/ci type")
    end

    it "returns empty for no match" do
      matches = H2code::TUI::CommandRegistry.match("/xyz")
      matches.should be_empty
    end

    it "returns empty for empty prefix" do
      matches = H2code::TUI::CommandRegistry.match("")
      matches.should be_empty
    end

    it "matches single command exactly" do
      matches = H2code::TUI::CommandRegistry.match("/help")
      matches.size.should eq(1)
      matches[0].name.should eq("/help")
    end
  end

  describe ".find" do
    it "finds existing command" do
      cmd = H2code::TUI::CommandRegistry.find("/exit")
      cmd.should_not be_nil
      if c = cmd
        c.name.should eq("/exit")
      end
    end

    it "returns nil for unknown command" do
      H2code::TUI::CommandRegistry.find("/unknown").should be_nil
    end
  end

  describe ".names" do
    it "includes all command names" do
      names = H2code::TUI::CommandRegistry.names
      names.should contain("/help")
      names.should contain("/exit")
      names.should contain("/compact")
    end

    it "includes the session management commands" do
      names = H2code::TUI::CommandRegistry.names
      names.should contain("/sessions")
      names.should contain("/resume")
      names.should contain("/fork")
      names.should contain("/archive")
      names.should contain("/restore")
      names.should contain("/search")
      names.should contain("/rename")
      names.should contain("/title")
    end

    it "includes the cleanup command" do
      names = H2code::TUI::CommandRegistry.names
      names.should contain("/cleanup")
      cmd = H2code::TUI::CommandRegistry.find("/cleanup")
      cmd.should_not be_nil
      if c = cmd
        c.usage.should eq("[week|month|6months|year]")
      end
    end
  end
end
