# colorize is a banner-coloring nicety; fall back to plain strings when the
# gem is missing (e.g. stock system Ruby without `gem install colorize`) so
# rake tasks still run.
begin
  require "colorize"
rescue LoadError
  class String
    def colorize(_color)
      self
    end
  end
end
require "json"
require "open3"

# Resolve the build version: explicit H2CODE_VERSION wins, then the most
# recent git tag (`git describe --tags --abbrev=0`), then "0.0.0-dev".
# git is invoked via Open3 (no shell): a backtick-style `2>/dev/null`
# redirect goes through cmd.exe on Windows, which fails on the Unix
# /dev/null path and silently skips the git call entirely.
def h2code_build_version
  return ENV["H2CODE_VERSION"] if ENV.key?("H2CODE_VERSION")
  tag, _ = Open3.capture2("git", "describe", "--tags", "--abbrev=0", err: File::NULL)
  tag = tag.strip
  tag.empty? ? "0.0.0-dev" : tag
rescue Errno::ENOENT, RuntimeError
  "0.0.0-dev"
end

MINIAUDIO_DIR = File.expand_path("vendor/miniaudio", __dir__)

def windows?
  RUBY_PLATFORM =~ /mingw|mswin|cygwin/i
end

# Build the miniaudio C bridge via scripts/build_miniaudio.sh and return the
# link flags it prints. The script is the single source of truth for the
# bridge build and link flags — shared by the Rakefile, CI
# (.github/workflows) and crosspack (crosspack.yml) — including the MSVC path
# on Windows (bash from Git for Windows). CFLAGS selects the optimization
# level; the Windows/MSVC branch of the script always builds -O2. The script
# rebuilds unconditionally, so rake pays the ~4s cc+ar on every spec run.
def miniaudio_link_flags(release: false)
  out, status = Open3.capture2({ "CFLAGS" => release ? "-O2" : "-O0 -g" },
    "bash", File.expand_path("scripts/build_miniaudio.sh", __dir__))
  abort "miniaudio bridge build failed (scripts/build_miniaudio.sh)" unless status.success?
  out.lines.last.to_s.strip
end

# Run `crystal spec` for *path* (the whole suite when nil), building the
# miniaudio bridge first and wiring its link flags in — the single place that
# knows how to assemble a working spec invocation.
def run_specs(path = nil)
  link_flags = miniaudio_link_flags
  target = path ? "spec #{path}" : "spec"
  # Fail-fast in CI (GitHub Actions sets CI=true): stop at the first failing
  # example — the remaining failures are almost always cascades of the same
  # root cause, so surface it immediately instead of collecting them all.
  fail_fast = ENV["CI"] ? " --fail-fast" : ""
  sh "crystal #{target}#{fail_fast} --warnings none --no-color --link-flags \"#{link_flags}\""
end

# Invocation path for a binary built into the repo. On Windows Crystal appends
# .exe to the -o name and cmd.exe does not resolve a Unix-style "./name"
# prefix, so use a backslash-relative path with the suffix there.
def bin_path(name)
  windows? ? ".\\#{name}.exe" : "./#{name}"
end

# Run the built h2code with extra environment variables. The Unix
# `VAR=value cmd` prefix syntax is not understood by cmd.exe (the shell treats
# the whole assignment as the command name and fails with exit 127), so the
# variables are exported in-process around the sh call instead.
def run_h2code(env = {}, args = "")
  saved = env.to_h { |k, _v| [k, ENV[k]] }
  begin
    env.each { |k, v| ENV[k] = v }
    sh "#{bin_path("h2code")} #{args}".strip
  ensure
    saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end
end

# Print a blue "building X" banner before each build step.
def building(name)
  puts "▶ Building #{name}".colorize(:blue)
end

# Windows locks a running executable against overwrites: linking over an
# h2code.exe that is currently running fails (on Linux/macOS the running
# process keeps the old inode and the path is simply replaced). Renaming a
# locked exe IS allowed on Windows, so move it aside before the link step to
# free the name; the stale copy is deleted on a later build once its process
# has exited. The matching .pdb is removed outright: a pdb left behind by an
# interrupted/failed link makes every later link die with LNK1201 ("error
# writing to program database") until it is deleted. No-op on non-Windows.
def rotate_windows_output(output)
  return unless windows?
  exe = File.file?("#{output}.exe") ? "#{output}.exe" : (File.file?(output) ? output : nil)
  rm_f "#{output}.pdb"
  return unless exe
  [".old", ".prev"].each do |suffix|
    slot = "#{exe}#{suffix}"
    begin
      rm_f slot
    rescue StandardError
      nil
    end
    next if File.exist?(slot) # slot still locked by an older running copy
    begin
      File.rename(exe, slot)
      return
    rescue SystemCallError
      nil
    end
  end
  warn "warning: could not move #{exe} aside — close running h2code instances and rebuild."
end

def build_h2code(output = "h2code", release: false)
  link_flags = miniaudio_link_flags(release: release)
  rotate_windows_output(output)
  flags = ["--warnings none", "--no-color"]
  flags << "--release" if release
  flags << "--link-flags \"#{link_flags}\""
  ENV["H2CODE_VERSION"] = h2code_build_version
  sh "crystal build src/h2code.cr -o #{output} #{flags.join(' ')}"
end

desc "Build the h2code binary (debug — for development and the mock demos)"
task :build do
  build_h2code
end

# Release builds for distribution flow through crosspack (crosspack.yml:
# crosspack deps/build/pack <target>). This task only feeds local dev flows
# (rake run:release, rake install) that want a release binary at ./h2code.
desc "Build a release binary at ./h2code (distribution builds: crosspack build, see crosspack.yml)"
task :build_release do
  building "h2code (release)"
  sh "bash scripts/build_h2code.sh \"\" h2code"
end

# `rake install` — same flow as the installers (runtime deps, install dir, PATH),
# but installs a binary built from this checkout instead of a release asset.
# The dependency/PATH logic lives in install.sh / install.ps1 (single source of
# truth); the built binary is passed to them as a local binary.
desc "Build (release) and install (~/.h2code/bin on Unix, %LOCALAPPDATA%\\h2code\\bin on Windows)"
task :install do
  unless system("crystal", "--version", out: File::NULL, err: File::NULL)
    abort "Crystal not found. Install it first: https://crystal-lang.org/install/"
  end
  Rake::Task["build_release"].invoke
  if windows?
    sh "powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -LocalBinary \"#{File.expand_path("h2code.exe", __dir__)}\""
  else
    sh "bash install.sh ./h2code"
  end
end

namespace :build do
  desc "Build every binary: h2code, ameba, lines_demo, mock_h2code, mockfast_h2code, mockshort_h2code"
  task :all => [:h2code, :ameba, :lines_demo, :mock_h2code, :mockfast_h2code, :mockshort_h2code]

  desc "Build the h2code binary (debug)"
  task :h2code do
    building "h2code"
    build_h2code
  end

  desc "Build bin/ameba"
  task :ameba do
    building "bin/ameba"
    sh "crystal build bin/ameba.cr -o bin/ameba --warnings none --no-color"
  end

  desc "Build bin/lines_demo"
  task :lines_demo do
    building "bin/lines_demo"
    sh "crystal build bin/lines_demo.cr -o bin/lines_demo --warnings none --no-color"
  end

  desc "Build bin/mock_h2code (simulated 100-tool LLM output)"
  task :mock_h2code do
    building "bin/mock_h2code"
    sh "crystal build bin/mock_h2code.cr -o bin/mock_h2code --warnings none --no-color"
  end

  desc "Build bin/mockfast_h2code (quick render check)"
  task :mockfast_h2code do
    building "bin/mockfast_h2code"
    sh "crystal build bin/mockfast_h2code.cr -o bin/mockfast_h2code --warnings none --no-color"
  end

  desc "Build bin/mockshort_h2code (short 10-line streamed answer + couple of tools)"
  task :mockshort_h2code do
    building "bin/mockshort_h2code"
    sh "crystal build bin/mockshort_h2code.cr -o bin/mockshort_h2code --warnings none --no-color"
  end
end

namespace :run do
  desc "Build (debug) and run the TUI"
  task :default => :build do
    run_h2code({}, "--yolo")
  end

  desc "Build with --release and run the TUI"
  task :release => :build_release do
    run_h2code({}, "--yolo")
  end
end

# Backward-compatible alias for `rake run:default`.
desc "Build (debug) and run the TUI (alias of run:default)"
task :run => "run:default"

desc "Run the test suite"
task :spec do
  run_specs
end

# ---------------------------------------------------------------------------
# Coverage (kcov): Crystal has no built-in coverage, so kcov profiles a single
# compiled spec binary. `crystal spec` cannot emit a standalone binary
# (--no-run was removed), so a generated entry file in tmp/ (gitignored)
# requires every spec file. kcov is resolved from PATH, falling back to the
# deb extracted into tmp/kcov-extract.
# ---------------------------------------------------------------------------

COVERAGE_ENTRY = File.expand_path("tmp/spec_cov_entry.cr", __dir__)
COVERAGE_BIN   = File.expand_path("tmp/spec_cov_bin", __dir__)
COVERAGE_DIR   = File.expand_path("tmp/coverage", __dir__)

def kcov_binary
  begin
    _out, status = Open3.capture2("kcov", "--version", err: File::NULL)
    return "kcov" if status.success?
  rescue Errno::ENOENT
    # kcov not on PATH — fall through to the local deb extract below.
  end
  local = File.expand_path("tmp/kcov-extract/usr/bin/kcov", __dir__)
  File.executable?(local) ? local : nil
end

desc "Run the test suite under kcov and report total src/ coverage"
task :coverage do
  kcov = kcov_binary
  unless kcov
    abort "kcov not found. Install it (the repo ships kcov_43+dfsg-2_amd64.deb: sudo dpkg -i), " \
          "or extract it locally: dpkg-deb -x kcov_43+dfsg-2_amd64.deb tmp/kcov-extract"
  end
  link_flags = miniaudio_link_flags
  spec_dir = File.expand_path("spec", __dir__)
  spec_files = Dir.glob("#{spec_dir}/**/*_spec.cr").sort.map { |p| p.delete_prefix("#{spec_dir}/") }
  File.write(COVERAGE_ENTRY,
    "# Generated by `rake coverage` — do not edit.\n" \
    "require \"../spec/spec_helper\"\n" +
    spec_files.map { |rel| "require \"../spec/#{rel}\"" }.join("\n") + "\n")
  sh "crystal build #{COVERAGE_ENTRY} -o #{COVERAGE_BIN} --warnings none --no-color --link-flags \"#{link_flags}\""
  rm_rf COVERAGE_DIR
  sh "#{kcov} --include-path=#{File.expand_path("src", __dir__)} " \
     "--exclude-path=#{spec_dir},#{File.expand_path("lib", __dir__)} " \
     "#{COVERAGE_DIR} #{COVERAGE_BIN}"
  # kcov writes coverage.json into kcov-merged/ or into per-binary dirs,
  # depending on how many child runs it collected — prefer the merged report,
  # fall back to the main binary's per-run dir.
  report = File.join(COVERAGE_DIR, "kcov-merged", "coverage.json")
  report = File.join(COVERAGE_DIR, File.basename(COVERAGE_BIN), "coverage.json") unless File.file?(report)
  if File.file?(report)
    data = JSON.parse(File.read(report))
    puts ("▶ Total coverage: #{data["percent_covered"]}% " \
          "(#{data["covered_lines"]}/#{data["total_lines"]} lines)").colorize(:blue)
  end
  puts "HTML report: #{File.join(COVERAGE_DIR, "index.html")}"
end
namespace :spec do  desc "Run integration specs only: tools executed headlessly (no user input) " \
       "against the real system — used by the CI integration matrix"
  task :integration do
    run_specs("spec/integration")
  end

  desc "Run CI port integration specs against the real GitHub/GitLab APIs " \
       "(read-only, public projects; no credentials required)"
  task :ci_port do
    ENV["H2CODE_CI_INTEGRATION"] = "1"
    run_specs("spec/integration/ci_port_integration_spec.cr")
  end
end

# Dash-spelled alias, mirroring i18n_check/tips_check conventions.
desc "Run integration specs only (alias of spec:integration)"
task :spec_integration => "spec:integration"

namespace :mock do
  desc "Run TUI with mock provider — default self-test script (parallel tools)"
  task :default => :build do
    run_h2code({"H2CODE_PROVIDER" => "mock", "NO_SANDBOX" => "1"}, "--tui-prompt 'mock' --yolo")
  end

  desc "Run TUI with mock provider — thinking streaming demo (~5s)"
  task :thinking => :build do
    run_h2code({"H2CODE_PROVIDER" => "mock", "NO_SANDBOX" => "1", "H2CODE_MOCK_SCRIPT" => "thinking"},
      "--tui-prompt 'mock' --yolo")
  end

  desc "Run TUI with mock provider — thinking + tool call demo"
  task :thinking_tools => :build do
    run_h2code({"H2CODE_PROVIDER" => "mock", "NO_SANDBOX" => "1", "H2CODE_MOCK_SCRIPT" => "thinking-tools"},
      "--tui-prompt 'mock' --yolo")
  end

  desc "Run TUI with mock provider — markdown rendering demo"
  task :markdown => :build do
    run_h2code({"H2CODE_PROVIDER" => "mock", "NO_SANDBOX" => "1", "H2CODE_MOCK_SCRIPT" => "markdown"},
      "--tui-prompt 'mock' --yolo")
  end

  desc "Run TUI with mock provider — broken-token markdown list streaming bug repro"
  task :markdown_tokens => :build do
    run_h2code({"H2CODE_PROVIDER" => "mock", "NO_SANDBOX" => "1", "H2CODE_MOCK_SCRIPT" => "markdown_tokens"},
      "--tui-prompt 'mock' --yolo")
  end

  desc "Run TUI with mock provider — sound notification on turn completion"
  task :sound => :build do
    run_h2code({"H2CODE_PROVIDER" => "mock", "NO_SANDBOX" => "1", "H2CODE_SOUND" => "1"},
      "--tui-prompt 'mock' --yolo")
  end

  desc "Run TUI with mock provider — sudo terminal exec demo (requires bin/mocksudo on PATH)"
  task :mocksudo => :build do
    sh "H2CODE_PROVIDER=mock NO_SANDBOX=1 H2CODE_MOCK_SCRIPT=sudo PATH=#{File.dirname(__FILE__)}/bin:$PATH ./h2code --tui-prompt 'mock' --yolo"
  end

  desc "Run TUI with mock provider — TodoList completion → log migration demo"
  task :todos => :build do
    run_h2code({"H2CODE_PROVIDER" => "mock", "NO_SANDBOX" => "1", "H2CODE_MOCK_SCRIPT" => "todos"},
      "--tui-prompt 'mock' --yolo")
  end

  desc "Run TUI with mock provider — long-plan review (EnterPlanMode → Write → ExitPlanMode)"
  task :plan => :build do
    # NO_SANDBOX=1 disables the tool write confinement for mock demos.
    # The own-session carve-out (src/sandbox.cr) already allows plan files
    # inside the session store, but the mock also scribbles other paths,
    # so keep the whole guard off here as before.
    run_h2code({"H2CODE_PROVIDER" => "mock", "NO_SANDBOX" => "1", "H2CODE_MOCK_SCRIPT" => "plan"},
      "--tui-prompt 'mock' --yolo")
  end

  desc "Run TUI with mock provider — ReadMediaFile multi-part image delivery demo"
  task :image => :build do
    # Generate a text-rendering PNG via ImageMagick so the demo is
    # self-verifying (a real model can read the words back). Falls back to
    # the project logo when ImageMagick is unavailable.
    img = File.expand_path("tmp/mock_image_text.png", __dir__)
    mkdir_p File.dirname(img)
    text = "Hello H2Code, this is image text"
    bin = %w[magick convert].find { |b| system(b, "-version", out: File::NULL, err: File::NULL) }
    env = {"H2CODE_PROVIDER" => "mock", "NO_SANDBOX" => "1", "H2CODE_MOCK_SCRIPT" => "image"}
    if bin && system(bin, "-size", "800x300", "xc:white", "-fill", "black",
                     "-pointsize", "48", "-gravity", "center",
                     "-annotate", "+0+0", text, img)
      puts "▶ Generated #{img} (#{text.bytesize} chars of text rendered)".colorize(:blue)
      env["H2CODE_MOCK_IMAGE"] = img
    else
      puts "▶ ImageMagick not found — falling back to logo.png".colorize(:yellow)
    end
    run_h2code(env, "--tui-prompt 'mock' --yolo")
  end

  desc "Run TUI with mock provider — clipboard image paste demo (Ctrl+V inserts a placeholder; press Enter to send)"
  task :paste => :build do
    img = File.expand_path("tmp/mock_image_text.png", __dir__)
    mkdir_p File.dirname(img)
    text = "Hello H2Code, this is image text"
    bin = %w[magick convert].find { |b| system(b, "-version", out: File::NULL, err: File::NULL) }
    if bin && system(bin, "-size", "800x300", "xc:white", "-fill", "black",
                     "-pointsize", "48", "-gravity", "center",
                     "-annotate", "+0+0", text, img)
      puts "▶ Generated #{img} — it acts as the clipboard image".colorize(:blue)
    end
    run_h2code({"H2CODE_PROVIDER" => "mock", "NO_SANDBOX" => "1", "H2CODE_MOCK_SCRIPT" => "imagepaste",
                "H2CODE_CLIPBOARD_FILE" => img}, "--tui-prompt 'mock' --yolo")
  end

  # --- standalone mock binaries (built by build:mock_h2code / build:mockfast_h2code) ---

  desc "Build and run bin/mock_h2code (simulated 100-tool LLM output for render testing)"
  task :run => "build:mock_h2code" do
    sh bin_path("bin/mock_h2code")
  end

  desc "Build and run bin/mockfast_h2code (big plan + couple of tools for quick render check)"
  task :fast => "build:mockfast_h2code" do
    sh bin_path("bin/mockfast_h2code")
  end

  desc "Build and run bin/mockshort_h2code (short 10-line streamed answer + couple of tools)"
  task :short => "build:mockshort_h2code" do
    sh bin_path("bin/mockshort_h2code")
  end

  # Simulate a first run with no config so the setup wizard launches. H2CODE_HOME
  # is pointed at a throwaway dir inside the project and config.json is wiped
  # first, so the wizard sees an unconfigured state. Writes go to that throwaway
  # dir only — the real ~/.h2code is never touched. H2CODE_PROVIDER is NOT set:
  # setting it to "mock" would mark the provider as configured and skip the
  # wizard entirely.
  desc "Simulate a first run (no config) to exercise the setup wizard"
  task :welcome => :build do
    welcome_home = File.expand_path("tmp/h2code_welcome_home", __dir__)
    rm_rf welcome_home
    mkdir_p welcome_home
    run_h2code({"H2CODE_HOME" => welcome_home})
  end
end

namespace :mock do
  namespace :components do
    desc "Render the editor input box across wrapping test cases (self-test + LLM-friendly output)"
    task :input do
      sh "crystal run scripts/components/input_demo.cr --warnings none --no-color"
    end
  end
end

# ---------------------------------------------------------------------------
# i18n locale integrity check (delegates to scripts/i18n_check.cr — the same
# check that runs at compile time via the macro guard in src/i18n/i18n.cr)
# ---------------------------------------------------------------------------

namespace :i18n do
  desc "Check locale integrity: valid YAML, key parity with en.yml, duplicate keys, %{placeholder} parity"
  task :check do
    puts "▶ Checking i18n locale integrity".colorize(:blue)
    sh "crystal run scripts/i18n_check.cr --warnings none --no-color" do |ok, _res|
      abort "i18n check failed" unless ok
    end
  end
end

desc "Check locale integrity: valid YAML, key parity with en.yml, duplicate keys, %{placeholder} parity (alias of i18n:check)"
task :i18n_check => "i18n:check"

# ---------------------------------------------------------------------------
# Ripgrep detection check (delegates to scripts/rg_check.cr) — verifies rg is
# found via PATH entries and the Homebrew/cargo fallbacks, including the
# minimal-PATH case common on macOS (GUI/launchd parent without Homebrew dirs).
# ---------------------------------------------------------------------------

namespace :rg do
  desc "Check ripgrep (rg) detection: PATH entries + Homebrew/cargo fallbacks, incl. the minimal-PATH macOS case"
  task :check do
    puts "▶ Checking ripgrep detection".colorize(:blue)
    sh "crystal run scripts/rg_check.cr --warnings none --no-color" do |ok, _res|
      abort "ripgrep check failed" unless ok
    end
  end
end

# ---------------------------------------------------------------------------
# Startup tips integrity check (delegates to scripts/tips_check.cr) — verifies
# tips/*.json: one file per supported locale, valid JSON with non-empty
# code/text, and tip-code parity across languages.
# ---------------------------------------------------------------------------

namespace :tips do
  desc "Check tips integrity: valid JSON, one file per locale, tip-code parity with en.json"
  task :check do
    puts "▶ Checking tips integrity".colorize(:blue)
    sh "crystal run scripts/tips_check.cr --warnings none --no-color" do |ok, _res|
      abort "tips check failed" unless ok
    end
  end
end

desc "Check tips integrity: valid JSON, one file per locale, tip-code parity with en.json (alias of tips:check)"
task :tips_check => "tips:check"

# Aggregated pre-commit validation: locale + tips data integrity.
desc "Run pre-commit checks (i18n + tips integrity)"
task :precommit => ["i18n:check", "tips:check"]

desc "Remove build artifacts"
task :clean do
  rm_f(windows? ? Dir.glob("h2code.exe{,.old,.prev}") : "h2code")
  rm_f Dir.glob("#{MINIAUDIO_DIR}/miniaudio_bridge.{o,a,obj,lib}")
  rm_f File.join(MINIAUDIO_DIR, ".bridge_stamp")
  # crosspack trees: build/ (matrix artifacts.from) and builds/ + crosspacks/
  # (the staged build/pack output, see crosspack.yml)
  rm_rf %w[build builds crosspacks]
end
