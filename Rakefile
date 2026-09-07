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
MINIAUDIO_LIB = File.join(MINIAUDIO_DIR, "libminiaudio_bridge.a")

def windows?
  RUBY_PLATFORM =~ /mingw|mswin|cygwin/i
end

# Locate a Visual Studio installation via vswhere. Returns the installation
# path (forward slashes) or nil.
def find_vs_install
  vswhere = [
    "C:/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe",
    "C:/Program Files/Microsoft Visual Studio/Installer/vswhere.exe",
  ].find { |p| File.file?(p) }
  return nil unless vswhere
  install_path = `"#{vswhere}" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`.strip
  return nil if install_path.empty?
  install_path.tr("\\", "/")
end

# Locate an MSVC cl.exe on Windows. Crystal uses MSVC as its native toolchain,
# so the bridge must be compiled with cl.exe too — mixing a MinGW-compiled
# archive with the MSVC link step causes C-runtime symbol mismatches.
def find_msvc_cl
  # Already on PATH (Developer Command Prompt)?
  exts = ENV["PATHEXT"] ? ENV["PATHEXT"].split(";") : [".EXE", ".BAT", ".CMD"]
  ENV["PATH"].split(File::PATH_SEPARATOR).each do |dir|
    exts.each do |ext|
      candidate = File.join(dir, "cl#{ext}")
      return candidate if File.file?(candidate) && File.executable?(candidate)
    end
  end
  # Locate via vswhere (covers "Developer Command Prompt not open" cases).
  install_path = find_vs_install
  return nil unless install_path
  Dir.glob("#{install_path}/VC/Tools/MSVC/*/bin/Hostx64/x64/cl.exe").sort.last
end

# Set up the MSVC environment (INCLUDE, LIB, PATH) by running vcvarsall.bat.
# When cl.exe is launched from a plain cmd.exe the SDK headers/libs are not on
# the default search paths, so #include <stdio.h> fails with C1083.
# Idempotent: no-op if INCLUDE is already set (Developer Command Prompt).
def setup_msvc_environment
  return if ENV["INCLUDE"] && !ENV["INCLUDE"].empty?
  install_path = find_vs_install
  return unless install_path
  vcvarsall = "#{install_path}/VC/Auxiliary/Build/vcvarsall.bat"
  return unless File.file?(vcvarsall)
  # `call` runs vcvarsall inside the SAME cmd.exe instance that later executes
  # `set`. A bare `cmd /c "vcvarsall" ... && set` would lose the variables:
  # `&& set` runs in the outer shell, while vcvarsall only modified the child
  # cmd process which has already exited — leaving INCLUDE/LIB unset and
  # cl.exe failing with C1083 (stdio.h not found).
  output = `call "#{vcvarsall}" x64 >nul 2>nul & set`
  output.each_line do |line|
    key, val = line.chomp.split("=", 2)
    next unless key && val
    # Console output arrives in the OEM codepage; keep invalid bytes from
    # aborting ENV[]= for values with non-ASCII characters.
    ENV[key] = val.scrub
  end
  return if ENV["INCLUDE"] && !ENV["INCLUDE"].empty?
  warn "warning: vcvarsall ran but did not set INCLUDE — the Windows SDK may be missing.\n" \
       "Install the \"Desktop development with C++\" workload (includes the Windows SDK),\n" \
       "or build from the \"Developer Command Prompt for VS\"."
end

# Full linker flags for miniaudio: the object/archive path plus platform-specific
# backend libraries. On Linux the backend (PulseAudio/ALSA) is dlopened at
# runtime, so only -ldl/-lpthread/-lm are needed.
def miniaudio_link_flags
  if windows?
    "#{File.join(MINIAUDIO_DIR, "miniaudio_bridge.obj")} winmm.lib ole32.lib ksuser.lib"
  else
    extra = case RUBY_PLATFORM
            when /darwin/
              "-framework CoreAudio -framework AudioToolbox -framework CoreFoundation"
            else
              "-ldl -lpthread -lm"
            end
    "-L#{MINIAUDIO_DIR} -lminiaudio_bridge #{extra}"
  end
end

def build_miniaudio_bridge(release: false)
  if windows?
    setup_msvc_environment
    cl = find_msvc_cl
    unless cl
      abort "Could not find MSVC cl.exe. Open the \"Developer Command Prompt for VS\" " \
            "or install Visual Studio Build Tools with the \"Desktop development with C++\" workload."
    end
    obj = File.join(MINIAUDIO_DIR, "miniaudio_bridge.obj")
    rm_f Dir.glob("#{MINIAUDIO_DIR}/miniaudio_bridge.{o,a,obj,lib}")
    opt = release ? "-O2" : "-Od -Z7"
    sh "\"#{cl}\" -nologo #{opt} -c -I\"#{MINIAUDIO_DIR}\" " \
       "\"#{File.join(MINIAUDIO_DIR, "miniaudio_bridge.c")}\" -Fo\"#{obj}\""
  else
    cflags = release ? "-O2" : "-O0 -g"
    sh "cc -c #{cflags} -I#{MINIAUDIO_DIR} " \
       "#{File.join(MINIAUDIO_DIR, "miniaudio_bridge.c")} " \
       "-o #{File.join(MINIAUDIO_DIR, "miniaudio_bridge.o")}"
    sh "ar rcs #{MINIAUDIO_LIB} #{File.join(MINIAUDIO_DIR, "miniaudio_bridge.o")}"
  end
end

# Run `crystal spec` for *path* (the whole suite when nil), building the
# miniaudio bridge first and wiring its link flags in — the single place that
# knows how to assemble a working spec invocation.
def run_specs(path = nil)
  build_miniaudio_bridge
  link_flags = miniaudio_link_flags
  target = path ? "spec #{path}" : "spec"
  sh "crystal #{target} --warnings none --no-color --link-flags \"#{link_flags}\""
end

# Print a blue "building X" banner before each build step.
def building(name)
  puts "▶ Building #{name}".colorize(:blue)
end

def build_h2code(output = "h2code", release: false)
  build_miniaudio_bridge(release: release)
  link_flags = miniaudio_link_flags
  flags = ["--warnings none", "--no-color"]
  flags << "--release" if release
  flags << "--link-flags \"#{link_flags}\""
  ENV["H2CODE_VERSION"] = h2code_build_version
  sh "crystal build src/h2code.cr -o #{output} #{flags.join(' ')}"
end

desc "Build the h2code binary"
task :build do
  build_h2code
end

desc "Build the h2code binary with --release"
task :build_release do
  build_h2code(release: true)
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
    sh "./h2code --yolo"
  end

  desc "Build with --release and run the TUI"
  task :release => :build_release do
    sh "./h2code --yolo"
  end
end

# Backward-compatible alias for `rake run:default`.
desc "Build (debug) and run the TUI (alias of run:default)"
task :run => "run:default"

desc "Run the test suite"
task :spec do
  run_specs
end

namespace :spec do
  desc "Run integration specs only: tools executed headlessly (no user input) " \
       "against the real system — used by the CI integration matrix"
  task :integration do
    run_specs("spec/integration")
  end
end

# Dash-spelled alias, mirroring i18n_check/tips_check conventions.
desc "Run integration specs only (alias of spec:integration)"
task :spec_integration => "spec:integration"

namespace :mock do
  desc "Run TUI with mock provider — default self-test script (parallel tools)"
  task :default => :build do
    sh "H2CODE_PROVIDER=mock ./h2code --tui-prompt 'mock' --yolo"
  end

  desc "Run TUI with mock provider — thinking streaming demo (~5s)"
  task :thinking => :build do
    sh "H2CODE_PROVIDER=mock H2CODE_MOCK_SCRIPT=thinking ./h2code --tui-prompt 'mock' --yolo"
  end

  desc "Run TUI with mock provider — thinking + tool call demo"
  task :thinking_tools => :build do
    sh "H2CODE_PROVIDER=mock H2CODE_MOCK_SCRIPT=thinking-tools ./h2code --tui-prompt 'mock' --yolo"
  end

  desc "Run TUI with mock provider — markdown rendering demo"
  task :markdown => :build do
    sh "H2CODE_PROVIDER=mock H2CODE_MOCK_SCRIPT=markdown ./h2code --tui-prompt 'mock' --yolo"
  end

  desc "Run TUI with mock provider — broken-token markdown list streaming bug repro"
  task :markdown_tokens => :build do
    sh "H2CODE_PROVIDER=mock H2CODE_MOCK_SCRIPT=markdown_tokens ./h2code --tui-prompt 'mock' --yolo"
  end

  desc "Run TUI with mock provider — sound notification on turn completion"
  task :sound => :build do
    sh "H2CODE_PROVIDER=mock H2CODE_SOUND=1 ./h2code --tui-prompt 'mock' --yolo"
  end

  desc "Run TUI with mock provider — sudo terminal exec demo (requires bin/mocksudo on PATH)"
  task :mocksudo => :build do
    sh "H2CODE_PROVIDER=mock H2CODE_MOCK_SCRIPT=sudo PATH=#{File.dirname(__FILE__)}/bin:$PATH ./h2code --tui-prompt 'mock' --yolo"
  end

  desc "Run TUI with mock provider — TodoList completion → log migration demo"
  task :todos => :build do
    sh "H2CODE_PROVIDER=mock H2CODE_MOCK_SCRIPT=todos ./h2code --tui-prompt 'mock' --yolo"
  end

  desc "Run TUI with mock provider — long-plan review (EnterPlanMode → Write → ExitPlanMode)"
  task :plan => :build do
    sh "H2CODE_PROVIDER=mock H2CODE_MOCK_SCRIPT=plan ./h2code --tui-prompt 'mock' --yolo"
  end

  # --- standalone mock binaries (built by build:mock_h2code / build:mockfast_h2code) ---

  desc "Build and run bin/mock_h2code (simulated 100-tool LLM output for render testing)"
  task :run => "build:mock_h2code" do
    sh "./bin/mock_h2code"
  end

  desc "Build and run bin/mockfast_h2code (big plan + couple of tools for quick render check)"
  task :fast => "build:mockfast_h2code" do
    sh "./bin/mockfast_h2code"
  end

  desc "Build and run bin/mockshort_h2code (short 10-line streamed answer + couple of tools)"
  task :short => "build:mockshort_h2code" do
    sh "./bin/mockshort_h2code"
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
    sh "H2CODE_HOME=#{welcome_home} ./h2code"
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
  rm_f "h2code"
  rm_f Dir.glob("#{MINIAUDIO_DIR}/miniaudio_bridge.{o,a,obj,lib}")
end
