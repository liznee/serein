@echo off
setlocal
REM serein Relay launcher (PTY TUI + JSONL dual-channel mode)
REM
REM Usage:
REM   serein [project_name]   - start relay for given project
REM   serein --qr             - print QR code only, do not start Claude
REM
REM Requires: node-pty + ws (see package.json)

REM Backend URL (use your self-hosted server; no third-party default)
if exist "%~dp0..\private\personal.env.bat" call "%~dp0..\private\personal.env.bat"
if "%SEREIN_BACKEND%"=="" set "SEREIN_BACKEND=http://localhost:8080"

REM Agent dir (directory of this bat file)
set "SEREIN_AGENT_DIR=%~dp0"

node "%~dp0serein.mjs" %*
endlocal
