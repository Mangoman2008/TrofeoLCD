@echo off
rem ============================================================
rem  start.cmd - start the DSH data bridge on Windows
rem  (comments are ASCII on purpose: cmd.exe reads this file in the
rem   OEM code page, so UTF-8/GBK Chinese comments risk breaking it)
rem
rem  Layout: put dsh-bridge.mjs, start.cmd, stop.cmd and zstd.exe together.
rem  Prereq:
rem    1. Node.js   (e.g. C:\Program Files\nodejs\node.exe)
rem    2. zstd.exe  REQUIRED - the bridge needs it to decode session.jsonl.zstd.
rem       Windows has no zstd built in. Get the win64 build from
rem       https://github.com/facebook/zstd/releases and put zstd.exe in this
rem       folder (the bridge looks here first), or set DSH_LCD_ZSTD=<full path>.
rem       Without it the bridge runs but the screen never gets data.
rem
rem  Usage:
rem    start.cmd                    start
rem    start.cmd --weather Beijing  also fetch weather
rem    start.cmd --printer <url>    connect a Bambu printer
rem ============================================================
setlocal enabledelayedexpansion
set "D=%~dp0"
set "PIDFILE=%D%.bridge.pid"
set "LOG=%D%.bridge.log"

rem ---- locate node ----
set "NODE="
where node >nul 2>&1 && set "NODE=node"
if not defined NODE if exist "%ProgramFiles%\nodejs\node.exe" set "NODE=%ProgramFiles%\nodejs\node.exe"
if not defined NODE if exist "C:\Program Files\nodejs\node.exe" set "NODE=C:\Program Files\nodejs\node.exe"
if not defined NODE (
  echo [FAIL] node.exe not found. Install Node.js or add it to PATH.
  pause
  exit /b 1
)

rem ---- already running? ----
if exist "%PIDFILE%" (
  set /p OLD=<"%PIDFILE%"
  tasklist /FI "PID eq !OLD!" 2>nul | find "!OLD!" >nul && (
    echo already running ^(PID !OLD!^), log: %LOG%
    exit /b 0
  )
)

rem ---- check zstd ----
set "ZOK="
if exist "%D%zstd.exe" set "ZOK=1"
if defined DSH_LCD_ZSTD if exist "%DSH_LCD_ZSTD%" set "ZOK=1"
where zstd >nul 2>&1 && set "ZOK=1"
if not defined ZOK (
  echo [WARN] zstd.exe not found here, and not in PATH.
  echo        The bridge will fail to decode session.jsonl.zstd -
  echo        it will run but the screen stays empty.
  echo        Put zstd.exe in: %D%
)

rem ---- log rotation (keep it from growing forever) ----
if exist "%LOG%" (
  for %%A in ("%LOG%") do set "SZ=%%~zA"
  if !SZ! GTR 2097152 (
    move /Y "%LOG%" "%LOG%.1" >nul 2>&1
    echo [start.cmd] rotated log to .bridge.log.1
  )
)

rem ---- default args (same as start.sh) ----
set "ARGS=--summary 120 --deepseek-balance 600"
if defined DSH_LCD_PRINTER set "ARGS=%ARGS% --printer %DSH_LCD_PRINTER%"
if exist "%D%bg-grid.jpg" set "ARGS=%ARGS% --bg "%D%bg-grid.jpg""

rem ---- launch ----
rem --pid-file makes the bridge write its own PID (wmic is deprecated in Win11)
if exist "%PIDFILE%" del /q "%PIDFILE%" >nul 2>&1
cd /d "%D%"
start "dsh-bridge" /b /min "%NODE%" dsh-bridge.mjs %ARGS% --pid-file "%PIDFILE%" %* >> "%LOG%" 2>&1

set /a N=0
:waitpid
if exist "%PIDFILE%" goto gotpid
set /a N+=1
if !N! GEQ 10 goto nopid
ping -n 2 127.0.0.1 >nul 2>&1
goto waitpid

:gotpid
set /p BID=<"%PIDFILE%"
echo started ^(PID !BID!^). log: %LOG%
goto tail

:nopid
echo [WARN] could not confirm PID (bridge may still be starting, or failed).
echo        log: %LOG%

:tail
if exist "%LOG%" (
  echo ---- last log line ----
  set "LAST="
  for /f "usebackq delims=" %%L in ("%LOG%") do set "LAST=%%L"
  if defined LAST echo !LAST!
)
endlocal
