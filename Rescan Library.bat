@echo off
rem  Ludoria Nexus - force a full library rescan (visible console so you can watch it).
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "LudoriaNexus.ps1" -ScanOnly -Rescan
if errorlevel 1 pause
