@echo off
rem ===========================================================================
rem  Double-click wrapper for Test-Blocked.ps1
rem  Quick check: is this IP blocked from inside China?
rem
rem  KEEP THIS FILE PURE ASCII. Chinese text in a .bat corrupts cmd.exe's
rem  byte-offset reader after chcp, breaking every following line.
rem  All Chinese output comes from Test-Blocked.ps1.
rem ===========================================================================
setlocal enabledelayedexpansion
cd /d "%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Test-Blocked.ps1" %*
set "RC=!errorlevel!"

echo.
if "!RC!"=="0" echo *** OK - reachable ***
if "!RC!"=="1" echo *** BLOCKED or UNREACHABLE - read the verdict above ***
if "!RC!"=="2" echo *** PORT / SERVICE PROBLEM - IP is not fully blocked ***
if not "!RC!"=="0" if not "!RC!"=="1" if not "!RC!"=="2" echo *** FAILED (code !RC!) ***
echo.
pause
exit /b !RC!
