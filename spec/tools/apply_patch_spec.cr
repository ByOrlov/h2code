require "../spec_helper"

describe H2code::Tools::Patch do
  describe "parse" do
    it "rejects a patch without the Begin marker" do
      expect_raises(H2code::Tools::ApplyPatchError, /\*\*\* Begin Patch/) do
        H2code::Tools::Patch.parse("bad patch")
      end
    end

    it "rejects a patch without the End marker" do
      expect_raises(H2code::Tools::ApplyPatchError, /\*\*\* End Patch/) do
        H2code::Tools::Patch.parse("*** Begin Patch\n*** Add File: foo\n+hi")
      end
    end

    it "rejects an empty Update hunk" do
      expect_raises(H2code::Tools::ApplyPatchError, /is empty/) do
        H2code::Tools::Patch.parse("*** Begin Patch\n*** Update File: a.py\n*** End Patch")
      end
    end

    it "rejects an unprefixed change line" do
      expect_raises(H2code::Tools::ApplyPatchError, /must start with/) do
        H2code::Tools::Patch.parse("*** Begin Patch\n*** Update File: a.py\nbad line\n*** End Patch")
      end
    end

    it "parses add, delete, update-with-move hunks" do
      hunks = H2code::Tools::Patch.parse(<<-PATCH)
        *** Begin Patch
        *** Add File: path/add.py
        +abc
        +def
        *** Delete File: path/delete.py
        *** Update File: path/update.py
        *** Move to: path/update2.py
        @@ def f():
        -    pass
        +    return 123
        *** End Patch
        PATCH

      hunks.size.should eq(3)
      add = hunks[0].as(H2code::Tools::Patch::AddFile)
      add.path.should eq("path/add.py")
      add.contents.should eq("abc\ndef\n")

      del = hunks[1].as(H2code::Tools::Patch::DeleteFile)
      del.path.should eq("path/delete.py")

      upd = hunks[2].as(H2code::Tools::Patch::UpdateFile)
      upd.path.should eq("path/update.py")
      upd.move_path.should eq("path/update2.py")
      upd.chunks.size.should eq(1)
      upd.chunks.first.change_context.should eq("def f():")
      upd.chunks.first.old_lines.should eq(["    pass"])
      upd.chunks.first.new_lines.should eq(["    return 123"])
    end

    it "parses context lines without an @@ header" do
      hunks = H2code::Tools::Patch.parse(<<-PATCH)
        *** Begin Patch
        *** Update File: file2.py
         import foo
        +bar
        *** End Patch
        PATCH

      upd = hunks.first.as(H2code::Tools::Patch::UpdateFile)
      chunk = upd.chunks.first
      chunk.change_context.should be_nil
      chunk.old_lines.should eq(["import foo"])
      chunk.new_lines.should eq(["import foo", "bar"])
    end

    it "parses the End of File marker" do
      hunks = H2code::Tools::Patch.parse(
        "*** Begin Patch\n*** Update File: f.txt\n@@\n+quux\n*** End of File\n*** End Patch")
      chunk = hunks.first.as(H2code::Tools::Patch::UpdateFile).chunks.first
      chunk.is_end_of_file?.should be_true
    end
  end

  describe "seek_sequence" do
    it "finds exact matches" do
      lines = ["foo", "bar", "baz"]
      H2code::Tools::Patch.seek_sequence(lines, ["bar", "baz"], 0, false).should eq(1)
    end

    it "falls back to trailing-whitespace matching" do
      lines = ["foo   ", "bar\t\t"]
      H2code::Tools::Patch.seek_sequence(lines, ["foo", "bar"], 0, false).should eq(0)
    end

    it "falls back to fully trimmed matching" do
      lines = ["    foo   ", "   bar\t"]
      H2code::Tools::Patch.seek_sequence(lines, ["foo", "bar"], 0, false).should eq(0)
    end

    it "returns nil when the pattern cannot fit" do
      H2code::Tools::Patch.seek_sequence(["one"], ["a", "b", "c"], 0, false).should be_nil
    end
  end
end

AP_WORK_DIR = "/tmp"

def write_ap_setup(name : String, body : String) : String
  path = File.join(AP_WORK_DIR, name)
  File.write(path, body)
  path
end

describe H2code::Tools::ApplyPatchTool do
  it "uses the canonical tool name" do
    H2code::Tools::ApplyPatchTool.new.name.should eq("ApplyPatch")
    H2code::Tools::ApplyPatchTool.new.name.should eq(H2code::Tools::Names::APPLY_PATCH)
  end

  it "adds, updates, and deletes multiple files in one call" do
    File.delete?(File.join(AP_WORK_DIR, "ap-multi-new.txt"))
    File.delete?(File.join(AP_WORK_DIR, "ap-multi-base.py.d"))
    write_ap_setup("ap-multi-base.py", "def f():\n    pass\n")

    tool = H2code::Tools::ApplyPatchTool.new(AP_WORK_DIR)
    result = tool.execute(JSON.parse(%({"input":"*** Begin Patch\\n*** Add File: ap-multi-new.txt\\n+hello\\n*** Update File: ap-multi-base.py\\n@@ def f():\\n-    pass\\n+    return 42\\n*** Delete File: ap-multi-base.py.d\\n*** End Patch"})))

    # Delete target does not exist yet → whole patch must fail atomically.
    result.is_error?.should be_true
    result.content.should contain("not found")
    File.exists?(File.join(AP_WORK_DIR, "ap-multi-new.txt")).should be_false

    File.write(File.join(AP_WORK_DIR, "ap-multi-base.py.d"), "x\n")
    result = tool.execute(JSON.parse(%({"input":"*** Begin Patch\\n*** Add File: ap-multi-new.txt\\n+hello\\n*** Update File: ap-multi-base.py\\n@@ def f():\\n-    pass\\n+    return 42\\n*** Delete File: ap-multi-base.py.d\\n*** End Patch"})))
    result.is_error?.should be_false
    result.content.should contain("A ap-multi-new.txt")
    result.content.should contain("M ap-multi-base.py")
    result.content.should contain("D ap-multi-base.py.d")

    File.read(File.join(AP_WORK_DIR, "ap-multi-new.txt")).should eq("hello\n")
    File.read(File.join(AP_WORK_DIR, "ap-multi-base.py")).should eq("def f():\n    return 42\n")
    File.exists?(File.join(AP_WORK_DIR, "ap-multi-base.py.d")).should be_false
  end

  it "applies sequential chunks in file order" do
    write_ap_setup("ap-ctx.txt", "alpha\nbeta\ngamma\nbeta\ndelta\n")

    tool = H2code::Tools::ApplyPatchTool.new(AP_WORK_DIR)
    result = tool.execute(JSON.parse(%({"input":"*** Begin Patch\\n*** Update File: ap-ctx.txt\\n@@ alpha\\n-beta\\n+BETA\\n@@\\n-beta\\n+beta2\\n*** End Patch"})))
    result.is_error?.should be_false

    File.read(File.join(AP_WORK_DIR, "ap-ctx.txt")).should eq("alpha\nBETA\ngamma\nbeta2\ndelta\n")
  end

  it "treats consecutive context lines as one contiguous chunk" do
    write_ap_setup("ap-ctx2.txt", "alpha\nbeta\ngamma\ndelta\n")

    tool = H2code::Tools::ApplyPatchTool.new(AP_WORK_DIR)
    result = tool.execute(JSON.parse(%({"input":"*** Begin Patch\\n*** Update File: ap-ctx2.txt\\n beta\\n-gamma\\n+GAMMA\\n*** End Patch"})))
    result.is_error?.should be_false

    File.read(File.join(AP_WORK_DIR, "ap-ctx2.txt")).should eq("alpha\nbeta\nGAMMA\ndelta\n")
  end

  it "moves a file via Move to" do
    File.delete?(File.join(AP_WORK_DIR, "ap-moved.txt"))
    write_ap_setup("ap-moveme.txt", "one\ntwo\n")

    tool = H2code::Tools::ApplyPatchTool.new(AP_WORK_DIR)
    result = tool.execute(JSON.parse(%({"input":"*** Begin Patch\\n*** Update File: ap-moveme.txt\\n*** Move to: ap-moved.txt\\n@@\\n-two\\n+TWO\\n*** End Patch"})))
    result.is_error?.should be_false
    result.content.should contain("moved from")

    File.exists?(File.join(AP_WORK_DIR, "ap-moveme.txt")).should be_false
    File.read(File.join(AP_WORK_DIR, "ap-moved.txt")).should eq("one\nTWO\n")
  end

  it "anchors an append at the end of file with the EOF marker" do
    write_ap_setup("ap-eof.txt", "start\nmiddle\n")

    tool = H2code::Tools::ApplyPatchTool.new(AP_WORK_DIR)
    result = tool.execute(JSON.parse(%({"input":"*** Begin Patch\\n*** Update File: ap-eof.txt\\n@@\\n+tail\\n*** End of File\\n*** End Patch"})))
    result.is_error?.should be_false
    File.read(File.join(AP_WORK_DIR, "ap-eof.txt")).should eq("start\nmiddle\ntail\n")
  end

  it "matches context tolerantly on trailing whitespace" do
    write_ap_setup("ap-ws.txt", "if x:   \n    run()\n")

    tool = H2code::Tools::ApplyPatchTool.new(AP_WORK_DIR)
    result = tool.execute(JSON.parse(%({"input":"*** Begin Patch\\n*** Update File: ap-ws.txt\\n@@ if x:\\n-    run()\\n+    walk()\\n*** End Patch"})))
    result.is_error?.should be_false
    File.read(File.join(AP_WORK_DIR, "ap-ws.txt")).should eq("if x:   \n    walk()\n")
  end

  it "preserves CRLF line endings on write-back" do
    write_ap_setup("ap-crlf.txt", "alpha\r\nbeta\r\n")

    tool = H2code::Tools::ApplyPatchTool.new(AP_WORK_DIR)
    result = tool.execute(JSON.parse(%({"input":"*** Begin Patch\\n*** Update File: ap-crlf.txt\\n-beta\\n+BETA\\n*** End Patch"})))
    result.is_error?.should be_false
    File.read(File.join(AP_WORK_DIR, "ap-crlf.txt")).should eq("alpha\r\nBETA\r\n")
  end

  it "fails without writing when context is not found" do
    write_ap_setup("ap-miss.txt", "aaa\nbbb\n")

    tool = H2code::Tools::ApplyPatchTool.new(AP_WORK_DIR)
    result = tool.execute(JSON.parse(%({"input":"*** Begin Patch\\n*** Update File: ap-miss.txt\\n@@ def nowhere():\\n-zzz\\n+qqq\\n*** End Patch"})))
    result.is_error?.should be_true
    result.content.should contain("Failed to find context")
    File.read(File.join(AP_WORK_DIR, "ap-miss.txt")).should eq("aaa\nbbb\n")
  end

  it "attaches a file_io display for a single-file update" do
    write_ap_setup("ap-disp.txt", "hello\n")

    tool = H2code::Tools::ApplyPatchTool.new(AP_WORK_DIR)
    result = tool.execute(JSON.parse(%({"input":"*** Begin Patch\\n*** Update File: ap-disp.txt\\n-hello\\n+world\\n*** End Patch"})))
    result.is_error?.should be_false

    display = result.display
    display.should_not be_nil
    if display
      display.kind.should eq("file_io")
      display.operation.should eq("edit")
      display.path.should eq("ap-disp.txt")
      display.before.should eq("hello\n")
      display.after.should eq("world\n")
    end
  end

  it "rejects an empty input" do
    result = H2code::Tools::ApplyPatchTool.new(AP_WORK_DIR).execute(JSON.parse(%q({})))
    result.is_error?.should be_true
    result.content.should contain("No patch provided")
  end
end
