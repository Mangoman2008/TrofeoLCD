@echo off
rem diag-x64.cmd - clean restart of the x64 build + dump diagnostics
rem ASCII only on purpose (cmd.exe reads this file in the OEM code page)
setlocal
set D=%~dp0
set EXE=%D%out\x64\dshlcd.exe
set LOG=%D%out\x64\dshlcd.log

if not exist "%EXE%" (
  echo [FAIL] not found: %EXE%
  echo        run build.cmd first
  pause
  exit /b 1
)

echo === killing every old dshlcd instance ===
taskkill /IM dshlcd2.exe /F >nul 2>&1 && echo   killed dshlcd2.exe (old v30 build)
taskkill /IM dshlcd.exe  /F >nul 2>&1 && echo   killed dshlcd.exe
timeout /t 2 /nobreak >nul

echo.
echo === files next to the exe (must include libusb-1.0.dll) ===
dir /b "%D%out\x64"

echo.
echo === clearing old log ===
if exist "%LOG%" del /q "%LOG%" >nul 2>&1

echo === starting x64 build (takes ~10s to settle) ===
start "dshlcd-x64" /D "%D%out\x64" "%EXE%"
timeout /t 10 /nobreak >nul

echo.
echo ================ /probe ================
curl -s http://127.0.0.1:54546/probe
echo.
echo ================ /diag ================
curl -s http://127.0.0.1:54546/diag
echo.
echo ================ log tail ================
if exist "%LOG%" (powershell -NoProfile -Command "Get-Content -Tail 20 -Encoding UTF8 '%LOG%'" 2>nul) else (echo no log at %LOG%)
echo.
echo Done. Please paste everything above back to the assistant.
pause
