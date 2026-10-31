@echo off
setlocal
set OUT=%~dp0out
set SRC=%~dp0src
set CSC=%~dp0roslyn\csc.exe
set LOG=%OUT%\variants.log
echo === variants %DATE% %TIME% === > "%LOG%"
if not exist "%~dp0icon\dshlcd.ico" echo [WARN] 缺少 icon\dshlcd.ico（exe 将没有图标） >> "%LOG%"
taskkill /IM dshlcd_arm64.exe /F >nul 2>&1
taskkill /IM dshlcd_x64.exe /F >nul 2>&1
timeout /t 2 /nobreak >nul
for %%P in (arm64 x64) do (
  "%CSC%" /nologo /target:winexe /platform:%%P /optimize+ /codepage:65001 ^
    /out:"%OUT%\dshlcd_%%P_v__VER__.exe" /win32icon:"%~dp0icon\dshlcd.ico" ^
    /reference:System.dll /reference:System.Drawing.dll /reference:System.Windows.Forms.dll ^
    "%SRC%\*.cs" >> "%LOG%" 2>&1
  if errorlevel 1 ( echo [FAIL] %%P >> "%LOG%" ) else ( echo [OK] %%P >> "%LOG%" )
  for %%A in ("%OUT%\dshlcd_%%P_v__VER__.exe") do echo %%P size=%%~zA >> "%LOG%"
)
