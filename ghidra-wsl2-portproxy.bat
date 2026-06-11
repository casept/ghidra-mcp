@echo off
:: ghidra-wsl2-portproxy.bat
:: Forwards Windows loopback port 8089 so the ghidra-mcp bridge in WSL2 can
:: reach Ghidra.  Ghidra listens on 127.0.0.1:8089 (Windows loopback only);
:: WSL2 cannot reach that address directly.  This script adds a portproxy rule
:: that catches connections on all interfaces and forwards them to loopback.
::
:: Run once per Windows session (rules survive reboot via netsh persistence).
:: Run again if WSL2 assigns a new subnet (rare — rules are IP-agnostic).
::
:: Requires Administrator rights — the script self-elevates via UAC if needed.

setlocal EnableDelayedExpansion

:: --- Admin check / self-elevation ------------------------------------------
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -NoProfile -Command ^
        "Start-Process -FilePath '%~f0' -Verb RunAs -Wait"
    exit /b
)

set PORT=8089

:: --- portproxy rule ---------------------------------------------------------
echo.
echo [1/3] Adding portproxy:  0.0.0.0:%PORT%  -^>  127.0.0.1:%PORT%
netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=%PORT% >nul 2>&1
netsh interface portproxy add v4tov4 ^
    listenaddress=0.0.0.0 ^
    listenport=%PORT% ^
    connectaddress=127.0.0.1 ^
    connectport=%PORT%
if %errorlevel% neq 0 (
    echo ERROR: portproxy add failed.
    pause & exit /b 1
)

:: --- firewall rule ----------------------------------------------------------
echo [2/3] Adding firewall inbound rule for TCP %PORT%...
netsh advfirewall firewall delete rule name="Ghidra MCP WSL2 (%PORT%)" >nul 2>&1
netsh advfirewall firewall add rule ^
    name="Ghidra MCP WSL2 (%PORT%)" ^
    dir=in ^
    action=allow ^
    protocol=TCP ^
    localport=%PORT% ^
    description="Allows WSL2 to reach Ghidra MCP on Windows loopback via portproxy"
if %errorlevel% neq 0 (
    echo WARNING: firewall rule add failed. You may need to allow port %PORT% manually.
)

:: --- show WSL2 host IP for bridge config ------------------------------------
echo [3/3] Detecting WSL2 host IP for GHIDRA_MCP_HOST...
for /f "tokens=*" %%i in ('powershell -NoProfile -Command ^
    "(Get-NetIPAddress -InterfaceAlias 'vEthernet (WSL)' -AddressFamily IPv4 2>$null).IPAddress"') do (
    set WSL_HOST_IP=%%i
)
if not defined WSL_HOST_IP (
    echo    Could not detect vEthernet (WSL) adapter IP.
    echo    Find it manually: ipconfig | findstr /C:"vEthernet (WSL)"
) else (
    echo    Windows host IP seen from WSL2: !WSL_HOST_IP!
    echo.
    echo    Set this in WSL2 before starting the bridge:
    echo      export GHIDRA_MCP_HOST=!WSL_HOST_IP!
    echo.
    echo    Or add to ~/.bashrc / ~/.profile for persistence:
    echo      echo 'export GHIDRA_MCP_HOST=!WSL_HOST_IP!' ^>^> ~/.bashrc
)

:: --- summary ----------------------------------------------------------------
echo.
echo Active portproxy rules:
netsh interface portproxy show v4tov4

echo.
echo Done.
pause
