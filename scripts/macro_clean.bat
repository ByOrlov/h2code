@echo off
rem Kill a lingering macro_run.exe and clear the Crystal cache entry for
rem scripts/i18n_check.cr (fixes LNK1104: cannot open macro_run.exe).
taskkill /f /im macro_run.exe
for /d %%D in ("%LOCALAPPDATA%\crystal\cache\*i18n_check.cr") do rmdir /s /q "%%D"
