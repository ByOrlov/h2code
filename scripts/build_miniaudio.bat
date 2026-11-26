@echo off
rem Windows-native counterpart of build_miniaudio.sh (no bash required):
rem locate Visual Studio via vswhere, import the MSVC environment with
rem vcvars64, compile the miniaudio bridge into
rem vendor\miniaudio\miniaudio_bridge.obj. Mirrors the MSVC branch of the
rem bash script (same vswhere query, same flags); the MinGW fallback is
rem deliberately omitted — Crystal's native Windows toolchain is MSVC.
rem The linker flags are declared statically in shard.yml
rem (binaries: h2code: link_flags: windows:) — carat does not consume
rem this script's output; the trailing echo is parity/debug only.
setlocal
set "ROOT=%~dp0.."
set "MA_DIR=%ROOT%\vendor\miniaudio"

if not exist "%MA_DIR%\miniaudio_bridge.c" goto :no_source

set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" set "VSWHERE=%ProgramFiles%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" goto :no_vswhere

set "VSROOT="
for /f "usebackq delims=" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do if not defined VSROOT set "VSROOT=%%i"
if not defined VSROOT goto :no_vs
if not exist "%VSROOT%\VC\Auxiliary\Build\vcvars64.bat" goto :no_vcvars

rem Import the MSVC toolchain into this session (cl on PATH, INCLUDE/LIB).
call "%VSROOT%\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
if errorlevel 1 goto :no_vcvars

cl -nologo -O2 -c -I"%MA_DIR%" "%MA_DIR%\miniaudio_bridge.c" -Fo"%MA_DIR%\miniaudio_bridge.obj"
if errorlevel 1 exit /b 1

echo %MA_DIR%\miniaudio_bridge.obj winmm.lib ole32.lib ksuser.lib
exit /b 0

:no_source
echo error: %MA_DIR%\miniaudio_bridge.c not found 1>&2
exit /b 1

:no_vswhere
echo error: vswhere.exe not found - install Visual Studio with the C++ workload ^(Microsoft.VisualStudio.Component.VC.Tools.x86.x64^) 1>&2
exit /b 1

:no_vs
echo error: no Visual Studio installation with the C++ tools found 1>&2
exit /b 1

:no_vcvars
echo error: vcvars64.bat failed - incomplete MSVC installation 1>&2
exit /b 1
