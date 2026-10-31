@echo off
rem ============================================================
rem  dshlcd Windows build script
rem  Builds x64 (and optionally ARM64) into separate folders, each
rem  with the matching libusb DLL.
rem  Why: this VM is Windows 11 ARM64. /platform:anycpu produced a
rem  process that could not load libusb -> BadImageFormatException
rem  0x8007000B. csc valid values: anycpu anycpu32bitpreferred x86
rem  Itanium x64 arm   (note: "arm", NOT "ARM64").
rem  (comments are ASCII on purpose: cmd.exe reads this file in the
rem   OEM code page, so non-ASCII comments break parsing)
rem ============================================================
setlocal enabledelayedexpansion
set HERE=%~dp0
set SRC=%HERE%src
set OUT=%HERE%out
set CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe
if not exist "%OUT%" mkdir "%OUT%"
set LOG=%OUT%\build.log
echo === build %DATE% %TIME% === > "%LOG%"
if not exist "%CSC%" (
  echo [FAIL] csc not found: %CSC% >> "%LOG%"
  echo [FAIL] csc not found: %CSC%
  exit /b 1
)
taskkill /IM dshlcd.exe /F >nul 2>&1

rem ---- x64 (primary; pairs with libusb-1.0-x64.dll) ----
call :build x64 "%OUT%\x64\dshlcd.exe"

rem ---- arm64 (optional; csc uses "arm" spelled platform name) ----
if defined ALSO_ARM call :build arm "%OUT%\arm64\dshlcd.exe"

findstr /C:"error CS" "%LOG%" >nul 2>&1
if not errorlevel 1 goto failed
echo [OK] compiled >> "%LOG%"
echo.
echo [OK] compiled
echo   run: %OUT%\x64\dshlcd.exe
echo   log: %LOG%
exit /b 0

:failed
echo [FAIL] compile failed >> "%LOG%"
echo ============================================
echo [FAIL] compile failed - see %LOG%
echo ============================================
findstr /C:"error CS" "%LOG%"
exit /b 1

rem ==== :build ARCH OUTEXE ====
:build
set ARCH=%~1
set EXE=%~2
set DST=%~dp2
if not exist "%DST%" mkdir "%DST%" >nul 2>&1
echo --- %ARCH% --- >> "%LOG%"
"%CSC%" /nologo /target:winexe /platform:%ARCH% /optimize+ /codepage:65001 /warn:4 ^
  /out:"%EXE%" /win32icon:"%HERE%icon\dshlcd.ico" ^
  /reference:System.dll ^
  /reference:System.Drawing.dll ^
  /reference:System.Windows.Forms.dll ^
  "%SRC%\*.cs" >> "%LOG%" 2>&1
for %%A in ("%EXE%") do echo %ARCH% size=%%~zA bytes >> "%LOG%"
rem pair the matching libusb DLL into the same folder
if /I "%ARCH%"=="x64" copy /Y "%HERE%libusb-1.0-x64.dll" "%DST%libusb-1.0.dll" >nul 2>&1
if /I "%ARCH%"=="arm" if exist "%HERE%libusb-1.0-arm64.dll" copy /Y "%HERE%libusb-1.0-arm64.dll" "%DST%libusb-1.0.dll" >nul 2>&1
call :copyasset "%DST%" bg_sample.jpg
call :copyasset "%DST%" trcc_official_1.png
call :copyasset "%DST%" trcc_official_2.png
call :copyasset "%DST%" trcc_official_3.png
call :copyasset "%DST%" trcc_official_4.png
call :copyasset "%DST%" trcc_official_5.png
goto :eof

rem ==== :copyasset DESTDIR NAME ====
:copyasset
set DST=%~1
set NM=%~2
if exist "%DST%%NM%" goto :eof
if exist "%HERE%assets\%NM%" copy /Y "%HERE%assets\%NM%" "%DST%%NM%" >nul 2>&1
if exist "%DST%%NM%" goto :eof
if exist "%HERE%%NM%" copy /Y "%HERE%%NM%" "%DST%%NM%" >nul 2>&1
goto :eof
