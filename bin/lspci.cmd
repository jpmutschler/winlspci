@echo off
REM winlspci -- lspci for Windows. See ..\README.md
REM Reads Windows' PnP/PCI enumeration; no kernel driver, so no config space.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0lspci.ps1" %*
