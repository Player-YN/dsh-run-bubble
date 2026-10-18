@echo off
rem dsh-chat Windows entry point (source tree).
rem Locates this directory, forwards all arguments untouched, and preserves the
rem exit code. chcp 65001 keeps UTF-8 output (Chinese titles/prompts) readable
rem in the classic console; the previous code page is restored on exit.
rem Set DSH_NODE to an absolute node.exe path to override PATH lookup.
setlocal EnableExtensions

if defined DSH_NODE goto run_node
where node >nul 2>&1
if errorlevel 1 (
  echo dsh-chat: node.exe not found on PATH. Install Node.js 20+ or set DSH_NODE to node.exe.>&2
  exit /b 127
)
:run_node

for /f "tokens=2 delims=:" %%A in ('chcp') do set "DSH_CHAT_OLDCP=%%A"
if defined DSH_CHAT_OLDCP set "DSH_CHAT_OLDCP=%DSH_CHAT_OLDCP: =%"
chcp 65001 >nul 2>&1

if defined DSH_NODE (
  "%DSH_NODE%" "%~dp0dsh-chat.mjs" %*
) else (
  node "%~dp0dsh-chat.mjs" %*
)
set "DSH_CHAT_CODE=%ERRORLEVEL%"

if defined DSH_CHAT_OLDCP chcp %DSH_CHAT_OLDCP% >nul 2>&1
exit /b %DSH_CHAT_CODE%
