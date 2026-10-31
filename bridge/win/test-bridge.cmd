@echo off
rem test-bridge.cmd - independent test: does the bridge ACTUALLY send UDP packets?
rem ASCII only (cmd.exe reads this file in the OEM code page)
setlocal enabledelayedexpansion
set D=%~dp0
set PORT=54599
set NODE=
where node >nul 2>&1 && set "NODE=node"
if not defined NODE if exist "%ProgramFiles%\nodejs\node.exe" set "NODE=%ProgramFiles%\nodejs\node.exe"
if not defined NODE if exist "C:\Program Files\nodejs\node.exe" set "NODE=C:\Program Files\nodejs\node.exe"
if not defined NODE goto nonode
echo node: %NODE%
echo.
echo === step 1: start a bridge instance on port %PORT% ===
if exist "%D%bridge-test.log" del /q "%D%bridge-test.log"
if exist "%D%bridge-test.pid" del /q "%D%bridge-test.pid"
start "bridge-test" /b /min cmd /c ""%NODE%" dsh-bridge.mjs --port %PORT% --pid-file "%D%bridge-test.pid%" >> "%D%bridge-test.log" 2>&1"
timeout /t 5 /nobreak >nul
if not exist "%D%bridge-test.pid" goto nopid
set /p BPID=<"%D%bridge-test.pid%"
echo   bridge started, pid=!BPID!
goto listen

:nopid
echo   [WARN] no pid file - the bridge probably failed to start

:listen
echo.
echo === step 2: listen on port %PORT% for 8 seconds ===
"%NODE%" udp-listen.cjs %PORT%
echo.
echo === step 3: bridge-test.log content ===
if exist "%D%bridge-test.log" type "%D%bridge-test.log"
if not exist "%D%bridge-test.log" echo   no log file - the bridge never even started
echo.
echo === step 4: cleaning up test bridge ===
if exist "%D%bridge-test.pid" set /p BPID=<"%D%bridge-test.pid%"
if defined BPID taskkill /PID !BPID! /F >nul 2>&1
if defined BPID echo   killed pid !BPID!
echo.
echo Done. Paste everything above.
pause
exit /b 0

:nonode
echo [FAIL] node.exe not found. Install Node.js or add it to PATH.
pause
exit /b 1
