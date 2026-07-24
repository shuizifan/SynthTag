@echo off
rem AI renwu biaoqian tool launcher - double click to run, no install needed
cd /d "%~dp0"
start "" powershell -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0app.ps1"
