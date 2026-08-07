@echo off
rem  Ludoria - starts the native overlay tool (resident in tray).
rem  Prefers a compiled LudoriaNexus.exe; otherwise runs the .ahk (needs AutoHotkey v2).
cd /d "%~dp0"

if exist "LudoriaNexus.exe" (
    start "" "LudoriaNexus.exe"
    exit /b
)

rem run the script with AutoHotkey v2
if exist "%ProgramFiles%\AutoHotkey\v2\AutoHotkey64.exe" (
    start "" "%ProgramFiles%\AutoHotkey\v2\AutoHotkey64.exe" "LudoriaNexus.ahk"
    exit /b
)
if exist "%LocalAppData%\Programs\AutoHotkey\v2\AutoHotkey64.exe" (
    start "" "%LocalAppData%\Programs\AutoHotkey\v2\AutoHotkey64.exe" "LudoriaNexus.ahk"
    exit /b
)
rem fall back to file association
start "" "LudoriaNexus.ahk" 2>nul
if errorlevel 1 (
    echo AutoHotkey v2 not found. Install it, or compile LudoriaNexus.ahk with Ahk2Exe
    echo and drop LudoriaNexus.exe next to this bat.
    pause
)
