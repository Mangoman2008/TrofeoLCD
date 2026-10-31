@echo off
rem check-udp.cmd - who is bound to 54545, and does telemetry arrive?
rem ASCII only
setlocal enabledelayedexpansion
set D=%~dp0
echo === step 1: kill all app + bridge instances ===
taskkill /IM dshlcd.exe  /F >nul 2>&1 && echo   killed dshlcd.exe
taskkill /IM dshlcd2.exe /F >nul 2>&1 && echo   killed dshlcd2.exe
taskkill /IM node.exe    /F >nul 2>&1 && echo   killed node.exe
timeout /t 2 /nobreak >nul
echo.
echo === step 2: UDP listeners on 54545 (should be EMPTY now) ===
netstat -ano -p UDP | findstr ":54545"
echo   (above should be empty; if a PID shows up, that process owns the port)
echo.
echo === step 3: start ONE bridge (54545) ===
set NODE=
where node >nul 2>&1 && set "NODE=node"
if not defined NODE if exist "%ProgramFiles%\nodejs\node.exe" set "NODE=%ProgramFiles%\nodejs\node.exe"
start "bridge" /b /min cmd /c ""%NODE%" dsh-bridge.mjs --summary 120 --deepseek-balance 600 >> "%D%bridge-run.log" 2>&1"
timeout /t 4 /nobreak >nul
echo.
echo === step 4: UDP listeners on 54545 after bridge start ===
netstat -ano -p UDP | findstr ":54545"
echo.
echo === step 5: start app ===
start "dshlcd" /D "%D%out\x64" "%D%out\x64\dshlcd.exe"
timeout /t 12 /nobreak >nul
echo.
echo === step 6: telemetryPackets / bridgeAgeSec over 6 seconds ===
for /L %%I in (1,1,3) do (
  echo   --- sample %%I ---
  curl -s http://127.0.0.1:54546/diag | findstr /C:"telemetryPackets"
  timeout /t 2 /nobreak >nul
)
echo.
echo === step 7: UDP listeners NOW (app should own 54545) ===
netstat -ano -p UDP | findstr ":54545"
echo.
echo Done. Paste everything above.
pause
