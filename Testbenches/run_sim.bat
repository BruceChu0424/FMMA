@echo off
REM FMMA regression suite - Windows wrapper.
REM
REM run_sim.sh does the work; this just finds a bash to run it with, so
REM "double click and read the result" works on a plain Windows box.
REM
REM   run_sim.bat            run everything
REM   run_sim.bat --quick    Python tests only

setlocal

set "SCRIPT=%~dp0run_sim.sh"

for %%B in (
  "C:\Program Files\Git\bin\bash.exe"
  "C:\Program Files (x86)\Git\bin\bash.exe"
  "D:\Software\Git\bin\bash.exe"
) do (
  if exist %%B (
    %%B "%SCRIPT%" %*
    exit /b %ERRORLEVEL%
  )
)

where bash >nul 2>nul
if %ERRORLEVEL%==0 (
  bash "%SCRIPT%" %*
  exit /b %ERRORLEVEL%
)

echo Could not find bash. Install Git for Windows, or run:
echo    bash Testbenches/run_sim.sh
exit /b 1
