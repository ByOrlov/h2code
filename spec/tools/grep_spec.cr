require "../spec_helper"

describe H2code::Tools::Grep do
  # Shared test directory — created once, cleaned up at the end.
  test_dir = "/tmp/h2code-test-grep"
  FileUtils.rm_rf(test_dir) if Dir.exists?(test_dir)
  Dir.mkdir_p(test_dir)

  before_all do
    FileUtils.rm_rf(test_dir) if Dir.exists?(test_dir)
    Dir.mkdir_p(test_dir)
  end

  after_all do
    FileUtils.rm_rf(test_dir) if Dir.exists?(test_dir)
  end

  it "returns error for empty pattern" do
    grep = H2code::Tools::Grep.new(test_dir)
    result = grep.execute(JSON.parse(%({})))
    result.is_error?.should be_true
  end

  it "searches content and returns matching lines" do
    File.write(File.join(test_dir, "a.txt"), "hello world\nfoo bar\n")
    grep = H2code::Tools::Grep.new(test_dir)
    result = grep.execute(JSON.parse(%({"pattern": "hello", "output_mode": "content"})))
    result.is_error?.should be_false
    result.content.should contain("hello world")
    result.content.should_not contain("foo bar")
  end

  it "defaults to files_with_matches mode" do
    File.write(File.join(test_dir, "b.txt"), "searchterm here\n")
    grep = H2code::Tools::Grep.new(test_dir)
    result = grep.execute(JSON.parse(%({"pattern": "searchterm"})))
    result.is_error?.should be_false
    result.content.should contain("b.txt")
    result.content.should_not contain("searchterm here")
  end

  it "supports count_matches mode" do
    File.write(File.join(test_dir, "c.txt"), "dup\ndup\ndup\n")
    grep = H2code::Tools::Grep.new(test_dir)
    result = grep.execute(JSON.parse(%({"pattern": "dup", "output_mode": "count_matches"})))
    result.is_error?.should be_false
    result.content.should contain("Found")
    result.content.should contain("occurrence")
  end

  it "-C takes precedence over -A and -B" do
    File.write(File.join(test_dir, "prec.txt"), "line1\nMATCH\nline3\nline4\nMATCH2\nline6\n")
    grep = H2code::Tools::Grep.new(test_dir)
    result = grep.execute(JSON.parse(%({"pattern": "MATCH", "output_mode": "content", "-A": 3, "-B": 3, "-C": 1})))
    result.is_error?.should be_false
    # With -C=1 winning over -A/-B=3, only one line of context shows per
    # side; the second match's context stops at line6, not beyond.
    lines = result.content.split('\n')
    lines.should contain("prec.txt:2:MATCH")
    lines.should contain("prec.txt-3-line3")
    idx = lines.index!("prec.txt:2:MATCH")
    (lines[idx + 1]?).should eq("prec.txt-3-line3")
    # If -A=3 had won, two extra context lines would follow the match.
    result.content.should_not contain("line beyond")
  end

  it "filters sensitive files even with include_ignored=true" do
    File.write(File.join(test_dir, ".env"), "dup\n")
    File.write(File.join(test_dir, "plain_ignored.log"), "dup\n")
    File.write(File.join(test_dir, ".gitignore"), "*.log\n")
    grep = H2code::Tools::Grep.new(test_dir)
    result = grep.execute(JSON.parse(%({"pattern": "dup", "output_mode": "files_with_matches", "include_ignored": true})))
    result.is_error?.should be_false
    # The ignored log shows up (--no-ignore), the sensitive file never does
    # (excluded by the rg-side sensitive globs and/or the Crystal filter).
    result.content.should contain("plain_ignored.log")
    result.content.should_not contain(".env")
  end

  it "sorts count_matches by modification time (newest first)" do
    File.write(File.join(test_dir, "old_cnt.txt"), "dup\n")
    File.write(File.join(test_dir, "mid_cnt.txt"), "dup\n")
    File.write(File.join(test_dir, "new_cnt.txt"), "dup\n")
    File.utime(Time.utc(2024, 1, 1), Time.utc(2024, 1, 1), File.join(test_dir, "old_cnt.txt"))
    File.utime(Time.utc(2024, 1, 2), Time.utc(2024, 1, 2), File.join(test_dir, "mid_cnt.txt"))
    File.utime(Time.utc(2024, 1, 3), Time.utc(2024, 1, 3), File.join(test_dir, "new_cnt.txt"))

    grep = H2code::Tools::Grep.new(test_dir)
    result = grep.execute(JSON.parse(%({"pattern": "dup", "output_mode": "count_matches"})))
    result.is_error?.should be_false
    content = result.content
    new_idx = content.index("new_cnt.txt") || raise "new_cnt.txt missing"
    mid_idx = content.index("mid_cnt.txt") || raise "mid_cnt.txt missing"
    old_idx = content.index("old_cnt.txt") || raise "old_cnt.txt missing"
    (new_idx < mid_idx).should be_true
    (mid_idx < old_idx).should be_true
  end

  it "supports case-insensitive search with -i" do
    File.write(File.join(test_dir, "d.txt"), "Hello World\n")
    grep = H2code::Tools::Grep.new(test_dir)
    result = grep.execute(JSON.parse(%({"pattern": "hello", "output_mode": "content", "-i": true})))
    result.is_error?.should be_false
    result.content.should contain("Hello World")
  end

  it "supports context lines with -A" do
    File.write(File.join(test_dir, "e.txt"), "line1\nMATCH\nline3\n")
    grep = H2code::Tools::Grep.new(test_dir)
    result = grep.execute(JSON.parse(%({"pattern": "MATCH", "output_mode": "content", "-A": 1})))
    result.is_error?.should be_false
    result.content.should contain("MATCH")
    result.content.should contain("line3")
  end

  it "supports context lines with -B" do
    File.write(File.join(test_dir, "f.txt"), "line1\nMATCH\nline3\n")
    grep = H2code::Tools::Grep.new(test_dir)
    result = grep.execute(JSON.parse(%({"pattern": "MATCH", "output_mode": "content", "-B": 1})))
    result.is_error?.should be_false
    result.content.should contain("line1")
    result.content.should contain("MATCH")
  end

  it "supports glob filter" do
    File.write(File.join(test_dir, "g.cr"), "crystal_match\n")
    File.write(File.join(test_dir, "g.txt"), "crystal_match\n")
    grep = H2code::Tools::Grep.new(test_dir)
    result = grep.execute(JSON.parse(%({"pattern": "crystal_match", "glob": "*.cr"})))
    result.is_error?.should be_false
    result.content.should contain("g.cr")
    result.content.should_not contain("g.txt")
  end

  it "falls back to a glob for unknown type names like cr" do
    # ripgrep's Crystal type is `crystal`, not `cr` — an unknown type used
    # to fail the whole search with "unrecognized file type".
    File.write(File.join(test_dir, "type_fb.cr"), "type_fallback_target\n")
    File.write(File.join(test_dir, "type_fb.txt"), "type_fallback_target\n")
    grep = H2code::Tools::Grep.new(test_dir)
    result = grep.execute(JSON.parse(%({"pattern": "type_fallback_target", "type": "cr"})))
    result.is_error?.should be_false
    result.content.should contain("type_fb.cr")
    result.content.should_not contain("type_fb.txt")
  end

  it "passes known type names to rg directly" do
    File.write(File.join(test_dir, "type_known.cr"), "known_type_target\n")
    grep = H2code::Tools::Grep.new(test_dir)
    result = grep.execute(JSON.parse(%({"pattern": "known_type_target", "type": "crystal"})))
    result.is_error?.should be_false
    result.content.should contain("type_known.cr")
  end

  it "filters sensitive files" do
    File.write(File.join(test_dir, ".env"), "SECRET_KEY=hunter2\n")
    grep = H2code::Tools::Grep.new(test_dir)
    result = grep.execute(JSON.parse(%({"pattern": "SECRET_KEY", "output_mode": "content"})))
    result.is_error?.should be_false
    result.content.should_not contain("hunter2")
    result.content.should_not contain("SECRET_KEY")
  end

  it "filters .env files even in files_with_matches mode" do
    File.write(File.join(test_dir, ".env.local"), "API_TOKEN=xyz\n")
    grep = H2code::Tools::Grep.new(test_dir)
    result = grep.execute(JSON.parse(%({"pattern": "API_TOKEN"})))
    result.is_error?.should be_false
    # Content must never leak, but the filtered-file notice (listing the path) is expected.
    result.content.should_not contain("xyz")
  end

  it "excludes VCS metadata directories" do
    vcs_dir = File.join(test_dir, ".git")
    Dir.mkdir_p(vcs_dir)
    File.write(File.join(vcs_dir, "config"), "vcs_secret_data\n")
    grep = H2code::Tools::Grep.new(test_dir)
    result = grep.execute(JSON.parse(%({"pattern": "vcs_secret_data"})))
    result.is_error?.should be_false
    result.content.should_not contain("vcs_secret_data")
  end

  it "supports head_limit for pagination" do
    File.write(File.join(test_dir, "h.txt"), "pagetest\npagetest\npagetest\npagetest\npagetest\n")
    grep = H2code::Tools::Grep.new(test_dir)
    result = grep.execute(JSON.parse(%({"pattern": "pagetest", "output_mode": "content", "head_limit": 2})))
    result.is_error?.should be_false
    result.content.should contain("truncated")
  end

  it "supports offset for pagination" do
    File.write(File.join(test_dir, "i.txt"), "offsetline\noffsetline\noffsetline\noffsetline\noffsetline\n")
    grep = H2code::Tools::Grep.new(test_dir)
    result = grep.execute(JSON.parse(%({"pattern": "offsetline", "output_mode": "content", "head_limit": 0})))
    result.is_error?.should be_false
    result.content.should_not contain("truncated")
  end

  it "returns no matches message for non-existent pattern" do
    File.write(File.join(test_dir, "j.txt"), "some content\n")
    grep = H2code::Tools::Grep.new(test_dir)
    result = grep.execute(JSON.parse(%({"pattern": "ZZZ_NOT_FOUND_ZZZ", "output_mode": "content"})))
    result.is_error?.should be_false
    result.content.should contain("No matches")
  end

  it "supports include_ignored to search gitignored files" do
    Dir.mkdir_p(test_dir)
    File.write(File.join(test_dir, ".gitignore"), "ignored_file.txt\n")
    File.write(File.join(test_dir, "ignored_file.txt"), "ignored_content_here\n")
    grep = H2code::Tools::Grep.new(test_dir)
    # Without include_ignored, the file is excluded by .gitignore
    result1 = grep.execute(JSON.parse(%({"pattern": "ignored_content_here"})))
    result1.content.should_not contain("ignored_file.txt")
    # With include_ignored, it should be found
    result2 = grep.execute(JSON.parse(%({"pattern": "ignored_content_here", "include_ignored": true})))
    result2.content.should contain("ignored_file.txt")
  end

  it "accepts a native absolute path without joining it onto work_dir" do
    # Regression: Windows drive-absolute paths (`C:\f`) don't start with
    # '/', so they used to be treated as relative and joined onto the
    # work_dir, producing a bogus `C:\work\C:\file` search path.
    sub = File.expand_path(File.join(test_dir, "abs_sub"))
    FileUtils.mkdir_p(sub)
    File.write(File.join(sub, "abs.txt"), "absolute_target\n")
    grep = H2code::Tools::Grep.new(File.expand_path(test_dir))
    result = grep.execute(JSON.parse(%({"pattern": "absolute_target", "path": #{sub.to_json}})))
    result.is_error?.should be_false
    result.content.should contain("abs.txt")
  end
end
