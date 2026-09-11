require "../spec_helper"

# Helpers shared across examples — each test gets a fresh temp dir so
# gitignore / mtime state never leaks between examples.
def glob_fresh_dir(name : String) : String
  path = File.join(Dir.tempdir, "h2code-glob-spec-#{name}-#{Random::Secure.hex(4)}")
  Dir.mkdir_p(path)
  path
end

def glob_write(path : String, content : String = "x", mtime : Time? = nil) : Nil
  Dir.mkdir_p(File.dirname(path))
  File.write(path, content)
  if mtime
    File.utime(mtime, mtime, path)
  end
end

describe H2code::Tools::Glob do
  it "finds matching files by extension" do
    dir = glob_fresh_dir("basic")
    glob_write("#{dir}/a.cr")
    glob_write("#{dir}/b.cr")
    glob_write("#{dir}/c.txt")

    glob = H2code::Tools::Glob.new(dir)
    result = glob.execute(JSON.parse(%({"pattern": "*.cr"})))
    result.is_error?.should be_false
    result.content.should contain("a.cr")
    result.content.should contain("b.cr")
    result.content.should_not contain("c.txt")
  end

  it "returns error for empty pattern" do
    glob = H2code::Tools::Glob.new("/tmp")
    result = glob.execute(JSON.parse("{}"))
    result.is_error?.should be_true
  end

  it "returns error for non-existent directory" do
    glob = H2code::Tools::Glob.new("/tmp")
    result = glob.execute(JSON.parse(%({"pattern": "*.xyz", "path": "/nonexistent-h2code-glob-spec"})))
    result.is_error?.should be_true
    result.content.should contain("does not exist")
  end

  it "returns error when path is not a directory" do
    dir = glob_fresh_dir("notdir")
    glob_write("#{dir}/afile")
    glob = H2code::Tools::Glob.new(dir)
    result = glob.execute(JSON.parse(%({"pattern": "*", "path": "afile"})))
    result.is_error?.should be_true
    result.content.should contain("not a directory")
  end

  it "rejects a relative path that escapes the workspace via .." do
    dir = glob_fresh_dir("escape")
    glob = H2code::Tools::Glob.new(dir)
    result = glob.execute(JSON.parse(%({"pattern": "*", "path": "../"})))
    result.is_error?.should be_true
  end

  context "sensitive-file filtering" do
    it "filters out .env (rg prefilter)" do
      dir = glob_fresh_dir("sensitive")
      glob_write("#{dir}/.env")
      glob_write("#{dir}/keep.cr")

      glob = H2code::Tools::Glob.new(dir)
      result = glob.execute(JSON.parse(%({"pattern": "*"})))
      result.is_error?.should be_false
      result.content.should contain("keep.cr")
      result.content.should_not contain(".env")
    end

    it "filters .env.production via authoritative post-filter" do
      # `.env.production` is NOT caught by rg's prefilter (`**/.env` matches
      # only the literal `.env`), so this exercises the authoritative
      # `Sensitive.sensitive?` check on parsed paths.
      dir = glob_fresh_dir("sensitive-post")
      glob_write("#{dir}/.env.production")
      glob_write("#{dir}/keep.cr")

      glob = H2code::Tools::Glob.new(dir)
      result = glob.execute(JSON.parse(%({"pattern": "*"})))
      result.is_error?.should be_false
      result.content.should contain("keep.cr")
      result.content.should_not contain("env.production")
      result.content.should contain("Filtered 1 sensitive file(s)")
    end

    it "filters `credentials` via authoritative post-filter" do
      dir = glob_fresh_dir("credentials")
      glob_write("#{dir}/credentials")
      glob_write("#{dir}/keep.cr")

      glob = H2code::Tools::Glob.new(dir)
      result = glob.execute(JSON.parse(%({"pattern": "*"})))
      result.is_error?.should be_false
      result.content.should contain("keep.cr")
      result.content.should contain("Filtered 1 sensitive file(s)")
    end

    it "keeps .env.example (exemption)" do
      dir = glob_fresh_dir("exemption")
      glob_write("#{dir}/.env.example")

      glob = H2code::Tools::Glob.new(dir)
      result = glob.execute(JSON.parse(%({"pattern": "*"})))
      result.is_error?.should be_false
      result.content.should contain(".env.example")
    end

    it "filters SSH keys (id_rsa and variants)" do
      dir = glob_fresh_dir("ssh-keys")
      glob_write("#{dir}/id_rsa")
      glob_write("#{dir}/id_rsa.bak")
      glob_write("#{dir}/keep.cr")

      glob = H2code::Tools::Glob.new(dir)
      result = glob.execute(JSON.parse(%({"pattern": "*"})))
      result.is_error?.should be_false
      result.content.should contain("keep.cr")
      result.content.should_not contain("id_rsa\n")
    end
  end

  context "VCS exclusion" do
    it "never lists .git contents, even when an inside file matches the pattern" do
      # `.git/inside.cr` matches `*.cr`; without VCS exclusion it would be
      # returned. rg's `--glob '!.git'` prunes the whole subtree when the
      # positive pattern is specific (`*.cr`, not bare `*`).
      dir = glob_fresh_dir("vcs")
      glob_write("#{dir}/.git/inside.cr")
      glob_write("#{dir}/.git/HEAD")
      glob_write("#{dir}/keep.cr")

      glob = H2code::Tools::Glob.new(dir)
      result = glob.execute(JSON.parse(%({"pattern": "*.cr"})))
      result.is_error?.should be_false
      result.content.should contain("keep.cr")
      result.content.should_not contain(".git")
      result.content.should_not contain("inside.cr")
    end
  end

  context "ignore files" do
    # Note: rg's `--glob PATTERN` acts as an explicit include that overrides
    # `.gitignore` / `.ignore` rules. This matches the JS GlobTool — the
    # `include_ignored` flag only toggles rg's `--no-ignore`, it cannot
    # re-enable gitignore respect once a positive glob is supplied. The
    # tests below cover what we actually control.
    it "does not pass --no-ignore by default (smoke)" do
      dir = glob_fresh_dir("ignore-default")
      Process.run("git", ["init", "-q", dir], output: Process::Redirect::Close, error: Process::Redirect::Close)
      glob_write("#{dir}/keep.cr")

      glob = H2code::Tools::Glob.new(dir)
      result = glob.execute(JSON.parse(%({"pattern": "*.cr"})))
      result.is_error?.should be_false
      result.content.should contain("keep.cr")
    end

    it "accepts include_ignored: true and returns matches" do
      dir = glob_fresh_dir("include-ignored")
      Process.run("git", ["init", "-q", dir], output: Process::Redirect::Close, error: Process::Redirect::Close)
      glob_write("#{dir}/keep.cr")

      glob = H2code::Tools::Glob.new(dir)
      result = glob.execute(JSON.parse(%({"pattern": "*.cr", "include_ignored": true})))
      result.is_error?.should be_false
      result.content.should contain("keep.cr")
    end
  end

  context "mtime sorting" do
    it "returns most-recently-modified first" do
      dir = glob_fresh_dir("mtime")
      old_time = Time.utc(2020, 1, 1)
      new_time = Time.utc(2024, 6, 15)
      glob_write("#{dir}/old.cr", mtime: old_time)
      glob_write("#{dir}/new.cr", mtime: new_time)
      glob_write("#{dir}/mid.cr", mtime: Time.utc(2022, 1, 1))

      glob = H2code::Tools::Glob.new(dir)
      result = glob.execute(JSON.parse(%({"pattern": "*.cr"})))
      result.is_error?.should be_false

      lines = result.content.split('\n').reject(&.starts_with?('['))
      # Drop any summary trailer lines (e.g. "Filtered N sensitive…").
      lines = lines.reject { |l| l.includes?("sensitive") || l.includes?("Found") }
      lines.size.should be >= 3
      lines[0].should contain("new.cr")
      lines[1].should contain("mid.cr")
      lines[2].should contain("old.cr")
    end
  end

  context "brace expansion" do
    it "expands {ts,tsx}" do
      dir = glob_fresh_dir("brace")
      glob_write("#{dir}/a.ts")
      glob_write("#{dir}/b.tsx")
      glob_write("#{dir}/c.cr")

      glob = H2code::Tools::Glob.new(dir)
      result = glob.execute(JSON.parse(%({"pattern": "*.{ts,tsx}"})))
      result.is_error?.should be_false
      result.content.should contain("a.ts")
      result.content.should contain("b.tsx")
      result.content.should_not contain("c.cr")
    end

    it "translates wildcards inside braces" do
      # `{.github/**,deploy*,*.sh}` used to emit raw `**` into the regex,
      # failing with "quantifier does not follow a repeatable item".
      dir = glob_fresh_dir("brace-wildcard")
      glob_write("#{dir}/.github/workflows/ci.yml")
      glob_write("#{dir}/deploy.sh")
      glob_write("#{dir}/keep.cr")

      glob = H2code::Tools::Glob.new(dir)
      result = glob.execute(JSON.parse(%({"pattern": "{.github/**,deploy*,*.sh}"})))
      result.is_error?.should be_false
      result.content.should contain("ci.yml")
      result.content.should contain("deploy.sh")
      result.content.should_not contain("keep.cr")
    end

    it "matches character class [abc]" do
      dir = glob_fresh_dir("charclass")
      glob_write("#{dir}/a.cr")
      glob_write("#{dir}/b.cr")
      glob_write("#{dir}/x.cr")

      glob = H2code::Tools::Glob.new(dir)
      result = glob.execute(JSON.parse(%({"pattern": "[ab].cr"})))
      result.is_error?.should be_false
      result.content.should contain("a.cr")
      result.content.should contain("b.cr")
      result.content.should_not contain("x.cr")
    end
  end

  context "recursive patterns" do
    it "walks subdirectories with **" do
      dir = glob_fresh_dir("recursive")
      glob_write("#{dir}/src/a.ts")
      glob_write("#{dir}/src/sub/b.ts")
      glob_write("#{dir}/other/c.ts")

      glob = H2code::Tools::Glob.new(dir)
      result = glob.execute(JSON.parse(%({"pattern": "src/**/*.ts"})))
      result.is_error?.should be_false
      result.content.should contain("a.ts")
      result.content.should contain("b.ts")
      result.content.should_not contain("c.ts")
    end
  end

  context "match cap" do
    it "truncates at 100 matches with a marker" do
      dir = glob_fresh_dir("cap")
      (1..105).each { |i| glob_write("#{dir}/f#{i}.cr") }

      glob = H2code::Tools::Glob.new(dir)
      result = glob.execute(JSON.parse(%({"pattern": "*.cr"})))
      result.is_error?.should be_false
      result.content.should contain("Truncated at 100 matches")
      result.content.should contain("Only the first 100 matches are returned")
    end
  end

  context "pagination" do
    it "applies limit to cap the page size" do
      dir = glob_fresh_dir("limit")
      (1..5).each { |i| glob_write("#{dir}/f#{i}.cr") }

      glob = H2code::Tools::Glob.new(dir)
      result = glob.execute(JSON.parse(%({"pattern": "*.cr","limit":2})))
      result.is_error?.should be_false
      result.content.should contain("Truncated at 2 matches")
      result.content.should contain("offset=2 to page")
    end

    it "offset skips the first N matches" do
      dir = glob_fresh_dir("offset")
      # Deterministic mtime order: a newest, c oldest.
      glob_write("#{dir}/a.cr", mtime: Time.utc(2024, 1, 3))
      glob_write("#{dir}/b.cr", mtime: Time.utc(2024, 1, 2))
      glob_write("#{dir}/c.cr", mtime: Time.utc(2024, 1, 1))

      glob = H2code::Tools::Glob.new(dir)
      result = glob.execute(JSON.parse(%({"pattern": "*.cr","offset":1})))
      result.is_error?.should be_false
      result.content.should_not contain("a.cr\n")
      result.content.should contain("b.cr")
      result.content.should contain("c.cr")
    end

    it "reports a clean message when offset is past the end" do
      dir = glob_fresh_dir("offset-end")
      glob_write("#{dir}/a.cr")

      glob = H2code::Tools::Glob.new(dir)
      result = glob.execute(JSON.parse(%({"pattern": "*.cr","offset":5})))
      result.is_error?.should be_false
      result.content.should contain("No more matches")
    end

    it "limit=0 returns unlimited results" do
      dir = glob_fresh_dir("unlimited")
      (1..3).each { |i| glob_write("#{dir}/f#{i}.cr") }

      glob = H2code::Tools::Glob.new(dir)
      result = glob.execute(JSON.parse(%({"pattern": "*.cr","limit":0})))
      result.is_error?.should be_false
      result.content.should contain("f1.cr")
      result.content.should contain("f2.cr")
      result.content.should contain("f3.cr")
      result.content.should_not contain("Truncated")
    end
  end

  context "no matches" do
    it "returns a clean no-matches message" do
      dir = glob_fresh_dir("empty")
      glob_write("#{dir}/a.cr")

      glob = H2code::Tools::Glob.new(dir)
      result = glob.execute(JSON.parse(%({"pattern": "*.nomatch"})))
      result.is_error?.should be_false
      result.content.should contain("No matches")
    end
  end
end
