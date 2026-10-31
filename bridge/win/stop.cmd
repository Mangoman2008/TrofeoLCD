@echo off
rem stop.cmd - stop the DSH data bridge
setlocal
set "D=%~dp0"
set "PIDFILE=%D%.bridge.pid"
if not exist "%PIDFILE%" (
  echo no PID file. Trying to kill node.exe by name...
  taskkill /IM node.exe /F >nul 2>&1 && echo killed node.exe || echo no node.exe running
  exit /b 0
)
set /p PID=<"%PIDFILE%"
taskkill /PID %PID% /F >nul 2>&1 && echo stopped ^(PID %PID%^) || echo PID %PID% was not running
del /q "%PIDFILE%" >nul 2>&1
endlocal
