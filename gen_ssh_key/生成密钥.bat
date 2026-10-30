@echo off
rem ===========================================================================
rem  Double-click wrapper for New-SshKey.ps1
rem  Generate a local ssh-ed25519 key pair for logging into the VPS.
rem
rem  KEEP THIS FILE PURE ASCII. Chinese text in a .bat corrupts cmd.exe's
rem  byte-offset reader after chcp, breaking every following line.
rem  All Chinese output comes from New-SshKey.ps1.
rem ===========================================================================
setlocal enabledelayedexpansion
cd /d "%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0New-SshKey.ps1" %*
set "RC=!errorlevel!"

echo.
if "!RC!"=="0" echo *** DONE - public key is above, private key stays local ***
if not "!RC!"=="0" echo *** FAILED (code !RC!) - read the message above ***
echo.
pause
exit /b !RC!
