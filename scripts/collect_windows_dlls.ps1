# Collect the Windows runtime DLLs h2code.exe needs into a separate deps
# archive — a crosspack matrix step (crosspack.yml, the windows entry), ported
# verbatim from the old release.yml step so CI and local `crosspack build
# windows-11.0` produce the same asset.
#
#   pwsh -NoProfile scripts/collect_windows_dlls.ps1
#
# h2code.exe links dynamically against OpenSSL (libcrypto/libssl), libyaml and
# pcre2. The Crystal Windows install bundles these DLLs; ship them in a
# separate deps asset so install.ps1 can drop them next to h2code.exe on
# machines that lack a package manager.
$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")

$crystalDir = Split-Path (Get-Command crystal).Source
$needed = @('libcrypto-3-x64.dll','libssl-3-x64.dll','pcre2-8.dll','yaml.dll')
$found = @{}
Get-ChildItem -Path $crystalDir -Recurse -Filter *.dll -ErrorAction SilentlyContinue |
  Where-Object { $needed -contains $_.Name -and -not $found.ContainsKey($_.Name) } |
  ForEach-Object { $found[$_.Name] = $_.FullName }
foreach ($name in $needed) {
  if (-not $found.ContainsKey($name)) {
    Write-Host "::warning::DLL not found in Crystal tree: $name"
  }
}

$staging = "deps-staging"
New-Item -ItemType Directory -Path $staging -Force | Out-Null
foreach ($path in $found.Values) { Copy-Item $path -Destination $staging -Force }

New-Item -ItemType Directory -Path "build/bin" -Force | Out-Null
Compress-Archive -Path "$staging/*" -DestinationPath "build/bin/h2code-deps-windows.zip" -Force
Write-Host "Packaged deps:"
Get-ChildItem $staging | Format-Table Name,Length
