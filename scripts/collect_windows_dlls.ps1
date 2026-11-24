# Collect the Windows runtime DLLs h2code.exe needs into a separate deps
# archive — a crosspack matrix step (crosspack.yml, the windows entry), ported
# verbatim from the old release.yml step so CI and local `crosspack build
# windows-11.0` produce the same asset.
#
#   pwsh -NoProfile scripts/collect_windows_dlls.ps1
#
# h2code.exe links dynamically against OpenSSL (libcrypto/libssl), libyaml,
# pcre2, zlib, libiconv and the Boehm GC. The Crystal Windows install bundles
# these DLLs; ship them in a separate deps asset so install.ps1 can drop them
# next to h2code.exe on machines that lack a package manager.
# The exact file names shift between Crystal releases (OpenSSL 3 -> 4 renamed
# libcrypto-3-x64.dll -> libcrypto-4-x64.dll; zlib flipped zlib1.dll ->
# libz.dll), so OpenSSL is matched by family pattern and both zlib spellings
# are accepted -- a hardcoded list would silently package a bundle missing
# half the runtime after a Crystal upgrade.
$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")

$crystalDir = Split-Path (Get-Command crystal).Source
$fixedNames = @('pcre2-8.dll','yaml.dll','iconv-2.dll','gc.dll','libz.dll','zlib1.dll')
$familyPatterns = @('libcrypto-*-x64.dll','libssl-*-x64.dll')
$found = @{}
Get-ChildItem -Path $crystalDir -Recurse -Filter *.dll -ErrorAction SilentlyContinue |
  Where-Object {
    $n = $_.Name
    -not $found.ContainsKey($n) -and
    ($fixedNames -contains $n -or ($familyPatterns | Where-Object { $n -like $_ }))
  } |
  ForEach-Object { $found[$_.Name] = $_.FullName }

# Completeness report: one of each OpenSSL family, every fixed-name library,
# at least one zlib spelling. Warnings, not failures -- packaging what was
# found still beats aborting the matrix step.
foreach ($pattern in $familyPatterns) {
  if (-not ($found.Keys | Where-Object { $_ -like $pattern })) {
    Write-Host "::warning::DLL not found in Crystal tree: $pattern"
  }
}
foreach ($name in @('pcre2-8.dll','yaml.dll','iconv-2.dll','gc.dll')) {
  if (-not $found.ContainsKey($name)) {
    Write-Host "::warning::DLL not found in Crystal tree: $name"
  }
}
if (-not ($found.ContainsKey('libz.dll') -or $found.ContainsKey('zlib1.dll'))) {
  Write-Host "::warning::zlib runtime not found in Crystal tree (libz.dll / zlib1.dll)"
}

$staging = "deps-staging"
New-Item -ItemType Directory -Path $staging -Force | Out-Null
foreach ($path in $found.Values) { Copy-Item $path -Destination $staging -Force }

New-Item -ItemType Directory -Path "build/bin" -Force | Out-Null
Compress-Archive -Path "$staging/*" -DestinationPath "build/bin/h2code-deps-windows.zip" -Force
Write-Host "Packaged deps:"
Get-ChildItem $staging | Format-Table Name,Length
