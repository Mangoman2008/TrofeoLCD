@echo off
rem ============================================================
rem  build-bambu-test.cmd -- compile + run the Bambu self-test ONLY.
rem
rem  Needs no USB, no GUI, no screen: compiles just the data-fetch
rem  files, then really connects to Bambu cloud MQTT and prints the
rem  normalized PrinterInfo. Verifies the whole chain in seconds.
rem
rem  File list = the transitive compile closure, computed by
rem  tools/csharp_closure.py (do not hand-maintain it -- a missing
rem  file already cost us one failed round with CS0246 "PrinterInfo").
rem
rem  Options are forwarded to the self-test, e.g.
rem      build-bambu-test.cmd --seconds 60
rem
rem  ASCII only (cmd.exe reads this file in the OEM code page).
rem ============================================================
setlocal
set "HERE=%~dp0"
set "SRC=%HERE%src"
set "OUT=%HERE%out\bambutest"
set "CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
set "LOG=%HERE%out\bambu-build.log"

if not exist "%HERE%out" mkdir "%HERE%out" >nul 2>&1
if not exist "%OUT%" mkdir "%OUT%" >nul 2>&1
echo === bambu selftest build %DATE% %TIME% === > "%LOG%"

if not exist "%CSC%" goto nocsc
if not exist "%SRC%\MqttClient.cs" goto nosrc
if not exist "%SRC%\State.cs" goto nosrc
if not exist "%SRC%\BambuPrinter.cs" goto nosrc

echo --- compiling (9 files) ---
"%CSC%" /nologo /target:exe /platform:x64 /optimize+ /codepage:65001 /warn:4 ^
  /out:"%OUT%\bambu-selftest.exe" ^
  /reference:System.dll ^
  "%SRC%\Log.cs" ^
  "%SRC%\Json.cs" ^
  "%SRC%\State.cs" ^
  "%SRC%\MqttClient.cs" ^
  "%SRC%\BambuCloud.cs" ^
  "%SRC%\BambuState.cs" ^
  "%SRC%\BambuConfig.cs" ^
  "%SRC%\BambuPrinter.cs" ^
  "%HERE%tools\bambu-selftest.cs" >> "%LOG%" 2>&1

rem errorlevel stays 0 even when compilation fails -> look for "error CS"
findstr /C:"error CS" "%LOG%" >nul 2>&1
if not errorlevel 1 goto failed

echo.
echo ============================================
echo  [OK] compiled -- running self-test
echo ============================================
echo.
"%OUT%\bambu-selftest.exe" %*
set "RC=%ERRORLEVEL%"
echo.
echo (self-test exit code: %RC%)
goto end

:failed
echo.
echo ============================================
echo  [FAIL] compile failed -- please paste this to the assistant
echo ============================================
findstr /C:"error CS" "%LOG%"
echo.
echo full log: %LOG%
goto end

:nocsc
echo [FAIL] csc.exe not found: %CSC%
goto end

:nosrc
echo [FAIL] source not found. Expected MqttClient.cs / State.cs / BambuPrinter.cs under:
echo        %SRC%
echo        (run tools/sync_to_vm.sh on the host first)
goto end

:end
pause
