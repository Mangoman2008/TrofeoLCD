@echo off
rem start-bridge-sessions.cmd
rem Start the bridge so it reads DSH session data from the shared folder
rem (C:\dshlcd\sessions), which the HarmonyOS side keeps in sync.
rem ASCII only (cmd.exe reads this file in the OEM code page).
setlocal enabledelayedexpansion
set "D=%~dp0"
set "NODE="
where node >nul 2>&1 && set "NODE=node"
if not defined NODE if exist "%ProgramFiles%\nodejs\node.exe" set "NODE=%ProgramFiles%\nodejs\node.exe"
if not defined NODE goto nonode

echo === stopping old bridge / node ===
if exist "%D%.bridge.pid" set /p OPID=<"%D%.bridge.pid"
if defined OPID taskkill /PID !OPID! /F >nul 2>&1
taskkill /IM node.exe /F >nul 2>&1
timeout /t 1 /nobreak >nul

if not exist "%D%sessions" goto nosessions

echo === starting bridge with --sessions-root ===
if exist "%D%.bridge.log" del /q "%D%.bridge.log" >nul 2>&1
cd /d "%D%"
start "dsh-bridge" /b /min cmd /c ""%NODE%" dsh-bridge.mjs --sessions-root "%D%sessions" --summary 120 --deepseek-balance 600 --pid-file "%D%.bridge.pid" >> "%D%.bridge.log" 2>&1"
timeout /t 6 /nobreak >nul

echo.
echo === bridge.log (first 12 lines) ===
if exist "%D%.bridge.log" goto showlog
echo   (no log file - bridge failed to start)
goto checkdiag

:showlog
set /a LN=0
for /f "usebackq delims=" %%L in ("%D%.bridge.log") do (
  set /a LN+=1
  if !LN! LEQ 12 echo   %%L
)
echo   ... (total !LN! lines)

:checkdiag
echo.
echo === /diag telemetry fields ===
curl -s http://127.0.0.1:54546/diag
echo.
echo Done.
pause
exit /b 0

:nosessions
echo [FAIL] %D%sessions not found.
echo        On the HarmonyOS side run:  bash tools/sync_sessions_to_vm.sh
pause
exit /b 1

:nonode
echo [FAIL] node.exe not found.
pause
exit /b 1
