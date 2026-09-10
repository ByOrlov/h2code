# H2Code installer -- Windows (PowerShell).
# Usage:  irm https://raw.githubusercontent.com/ByOrlov/H2Code/master/install.ps1 | iex
#         powershell -File install.ps1 -LocalBinary h2code.exe   -- install a locally
#         built binary instead of downloading a release asset (used by `rake install`)
#Requires -Version 5.1
[CmdletBinding()] param([string]$LocalBinary)

$ErrorActionPreference = 'Stop'

$Repo = 'ByOrlov/H2Code'
$InstallDir = if ($env:H2CODE_INSTALL_DIR) { $env:H2CODE_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA 'h2code\bin' }
$BinName = 'h2code.exe'

# When driven from a console (rake install), skip the "Press Enter to close"
# pauses — they exist so a double-clicked window doesn't vanish instantly.
$ScriptMode = [bool]$LocalBinary

function Write-Info($msg) { Write-Host "  $msg" }
function Write-Err($msg)  { Write-Host "[x] $msg" -ForegroundColor Red }

# Prints a fatal error and pauses before exiting so the console window
# doesn't close before the message can be read (double-click / "Run with
# PowerShell" / irm|iex all tear down the window as soon as we exit).
function Fail($msg) {
    Write-Err $msg
    if (-not $ScriptMode) {
        Write-Host ""
        Read-Host "Press Enter to close" | Out-Null
    }
    exit 1
}

# Returns $true if the binary starts and prints a version (i.e. all its DLL
# dependencies resolve). Used to decide whether we need to install deps.
function Test-H2codeStarts($path) {
    try {
        $out = & $path --version 2>&1
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

# Installs the Windows runtime dependencies (OpenSSL, libyaml, pcre2) required
# by h2code.exe. Tries winget/choco for OpenSSL first, then unconditionally
# extracts the pinned DLL bundle next to the binary so all four DLLs are
# present regardless of which package manager (if any) is available.
function Ensure-WindowsDeps($binPath) {
    if (Test-H2codeStarts $binPath) {
        Write-Info "Runtime dependencies already available."
        return
    }
    Write-Info "Binary failed to start (likely missing DLLs). Installing runtime dependencies..."

    $installDir = Split-Path $binPath -Parent

    # OpenSSL via a system package manager, best-effort. Covers libcrypto/libssl
    # system-wide; pcre2/yaml are not in winget/choco and come from the bundle.
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget) {
        Write-Info "Trying: winget install OpenSSL.OpenSSL"
        & winget install --id OpenSSL.OpenSSL --silent --accept-package-agreements --accept-source-agreements 2>&1 |
            Out-Host
    } elseif (Get-Command choco -ErrorAction SilentlyContinue) {
        Write-Info "Trying: choco install openssl -y"
        & choco install openssl -y 2>&1 | Out-Host
    }

    # Guaranteed fallback: the pinned DLL bundle from the latest release.
    $depsUrl = "https://github.com/$Repo/releases/latest/download/h2code-deps-windows.zip"
    $depsZip = Join-Path $installDir "h2code-deps-windows.zip"
    try {
        Write-Info "Downloading runtime DLL bundle: $depsUrl"
        Invoke-WebRequest -Uri $depsUrl -OutFile $depsZip -UseBasicParsing
    } catch {
        Write-Err "Could not download runtime DLL bundle."
        Write-Err "Install OpenSSL (libcrypto/libssl), libyaml and pcre2 manually next to h2code.exe."
        return
    }
    try {
        Expand-Archive -Path $depsZip -DestinationPath $installDir -Force
        Write-Info "Extracted runtime DLLs to $installDir"
    } catch {
        Write-Err "Failed to extract runtime DLL bundle: $_"
        return
    } finally {
        Remove-Item $depsZip -ErrorAction SilentlyContinue
    }

    if (Test-H2codeStarts $binPath) {
        Write-Info "Runtime dependencies installed."
    } else {
        Write-Err "Binary still fails to start after installing dependencies."
        Write-Err "Run '$binPath --version' manually to see the missing DLL."
    }
}

# Installs ripgrep (rg.exe), required by the Grep and Glob tools. Tries
# winget/choco first; if neither is available (or they fail), downloads
# rg.exe directly from the ripgrep GitHub release into the install directory
# so it sits next to h2code.exe and is found via PATH.
function Ensure-Ripgrep($installDir) {
    if (Get-Command rg -ErrorAction SilentlyContinue) {
        Write-Info "ripgrep (rg) is available."
        return
    }

    Write-Info "ripgrep (rg) not found -- installing..."

    # Try winget.
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Info "Trying: winget install BurntSushi.ripgrep.MSVC"
        & winget install --id BurntSushi.ripgrep.MSVC --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-Host
        if (Get-Command rg -ErrorAction SilentlyContinue) {
            Write-Info "ripgrep installed via winget."
            return
        }
    }

    # Try choco.
    if (Get-Command choco -ErrorAction SilentlyContinue) {
        Write-Info "Trying: choco install ripgrep -y"
        & choco install ripgrep -y 2>&1 | Out-Host
        if (Get-Command rg -ErrorAction SilentlyContinue) {
            Write-Info "ripgrep installed via choco."
            return
        }
    }

    # Fallback: download rg.exe from the latest ripgrep GitHub release and
    # drop it next to h2code.exe so PATH picks it up.
    Write-Info "Downloading rg.exe from ripgrep GitHub releases..."
    try {
        $apiUrl = "https://api.github.com/repos/BurntSushi/ripgrep/releases/latest"
        $release = Invoke-RestMethod -Uri $apiUrl -UseBasicParsing
        $asset = $release.assets | Where-Object { $_.name -like "*x86_64-pc-windows-msvc.zip" } | Select-Object -First 1
        if (-not $asset) {
            Write-Err "Could not find ripgrep Windows release asset."
            Write-Err "Install ripgrep manually: https://github.com/BurntSushi/ripgrep#installation"
            return
        }
        $rgZip = Join-Path $installDir "ripgrep-download.zip"
        $extractDir = Join-Path $installDir "ripgrep-tmp"
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $rgZip -UseBasicParsing
        Expand-Archive -Path $rgZip -DestinationPath $extractDir -Force
        $rgExe = Get-ChildItem -Path $extractDir -Filter "rg.exe" -Recurse | Select-Object -First 1
        if ($rgExe) {
            Copy-Item -Path $rgExe.FullName -Destination (Join-Path $installDir "rg.exe") -Force
            Write-Info "Installed rg.exe to $installDir"
        } else {
            Write-Err "rg.exe not found in ripgrep archive."
        }
        Remove-Item $rgZip -ErrorAction SilentlyContinue
        Remove-Item $extractDir -Recurse -ErrorAction SilentlyContinue
    } catch {
        Write-Err "Could not download ripgrep: $_"
        Write-Err "Install ripgrep manually: https://github.com/BurntSushi/ripgrep#installation"
    }
}

# --- Detect arch --------------------------------------------------------------
# The whole main flow runs inside try/catch so that any unexpected terminating
# error (with $ErrorActionPreference = 'Stop') is reported and followed by a
# pause instead of silently killing the window.
try {
    $Arch = $env:PROCESSOR_ARCHITECTURE
    if ($Arch -eq 'AMD64' -or $Arch -eq 'x64') {
        $arch = 'x86_64'
    } else {
        Write-Err "Unsupported architecture: $Arch (this installer covers x86_64)"
        Fail "Installation aborted."
    }

    $Asset = "h2code-${arch}-windows.zip"
    $Url = "https://github.com/$Repo/releases/latest/download/$Asset"

    Write-Host "Installing H2Code for ${arch}-windows..." -ForegroundColor White
    if ($LocalBinary) {
        Write-Info "Source:        local build ($LocalBinary)"
    } else {
        Write-Info "Release asset: $Asset"
    }
    Write-Info "Install dir:   $InstallDir"

    # --- Download -----------------------------------------------------------------
    $Tmp = New-Item -ItemType Directory -Path ([System.IO.Path]::GetTempPath() + "h2code-$(New-Guid)") -Force
    try {
        if ($LocalBinary) {
            # Local binary mode (rake install from a source checkout): skip the
            # release download and install the given binary instead.
            if (-not (Test-Path $LocalBinary)) {
                Fail "Local binary not found: $LocalBinary"
            }
            $Src = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LocalBinary)
        } else {
            $ZipPath = Join-Path $Tmp.FullName $Asset
            Write-Info "Downloading $Url..."
            try {
                Invoke-WebRequest -Uri $Url -OutFile $ZipPath -UseBasicParsing
            } catch {
                Write-Err "Download failed: $_"
                Write-Err "If you're on ${arch}-windows, the asset may not be published yet."
                Write-Err "Check available assets at: https://github.com/$Repo/releases/latest"
                Fail "Installation aborted."
            }

            # --- Verify + extract -----------------------------------------------------
            Write-Info "Extracting..."
            Expand-Archive -Path $ZipPath -DestinationPath $Tmp.FullName -Force
            $Src = Join-Path $Tmp.FullName $BinName
        }

        # --- Install --------------------------------------------------------------
        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
        $Dest = Join-Path $InstallDir $BinName
        # Copy-Item -Force, not Move-Item: on re-installs Move-Item -Force is
        # known to fail with "Cannot create a file when that file already
        # exists" even though the destination is a regular file. The source
        # lives in $Tmp and is cleaned up in finally anyway.
        try {
            Copy-Item -Path $Src -Destination $Dest -Force
        } catch {
            Fail "Could not replace $Dest -- is h2code currently running? Close it and re-run the installer. ($_)"
        }
        Write-Info "Installed $Dest"

        # Startup tips data (tips/*.json, read from disk — see src/tips/tips.cr).
        # Only present when the release archive bundles them. Placed next to the
        # binary, which is one of the runtime tips lookup paths.
        $TipsSrc = Join-Path $Tmp.FullName 'tips'
        if (Test-Path $TipsSrc) {
            $TipsDir = Join-Path $InstallDir 'tips'
            New-Item -ItemType Directory -Path $TipsDir -Force | Out-Null
            Copy-Item -Path (Join-Path $TipsSrc '*.json') -Destination $TipsDir -Force
            Write-Info "Installed tips to $TipsDir"
        }

        # --- Runtime dependencies -------------------------------------------------
        # h2code.exe links dynamically against OpenSSL (libcrypto/libssl), libyaml
        # and pcre2. These DLLs are not present on a stock Windows install, so we
        # detect a missing-DLL failure by trying to run the binary and, on failure,
        # install the dependencies: OpenSSL via winget/choco when available, then
        # always drop the pinned runtime DLL bundle next to the binary.
        Ensure-WindowsDeps $Dest

        # ripgrep (rg.exe) -- required by the Grep and Glob tools. Installed via
        # winget/choco when available, otherwise downloaded directly from the
        # ripgrep GitHub release into the install directory.
        Ensure-Ripgrep $InstallDir

        # --- PATH -----------------------------------------------------------------
        $UserPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
        if ($UserPath -notlike "*$InstallDir*") {
            $NewPath = if ($UserPath) { "$UserPath;$InstallDir" } else { $InstallDir }
            [Environment]::SetEnvironmentVariable('PATH', $NewPath, 'User')
            # Also update the current session.
            $env:PATH = "$env:PATH;$InstallDir"
            Write-Info "Added $InstallDir to user PATH."
            Write-Info "Restart your terminal for PATH to take effect."
        }

        # --- Done -----------------------------------------------------------------
        Write-Host "[ok] H2Code installed." -ForegroundColor Green
        try {
            $Version = & $Dest --version 2>$null
            Write-Info "Version: $Version"
        } catch {
            Write-Info "Version: unknown"
        }
        Write-Info "Run 'h2code' to start. Use '/upgrade' inside the TUI to update later."
    }
    finally {
        Remove-Item -Recurse -Force $Tmp.FullName -ErrorAction SilentlyContinue
    }
} catch {
    Write-Err "Installation failed: $_"
    if ($_.Exception.InnerException -and $_.Exception.InnerException.Message) {
        Write-Err "Cause: $($_.Exception.InnerException.Message)"
    }
    if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
        Write-Host $_.InvocationInfo.PositionMessage -ForegroundColor DarkGray
    }
    if (-not $ScriptMode) {
        Write-Host ""
        Read-Host "Press Enter to close" | Out-Null
    }
    exit 1
}
