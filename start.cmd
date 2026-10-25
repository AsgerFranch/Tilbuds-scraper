@echo off
cd /d "%~dp0"
powershell -ExecutionPolicy Bypass -File "%~dp0opdater.ps1"
start "" "%~dp0index.html"
