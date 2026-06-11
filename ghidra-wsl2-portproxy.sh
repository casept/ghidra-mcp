#!/usr/bin/env bash
# Run ghidra-wsl2-portproxy.bat from WSL2.
# The .bat self-elevates via UAC if not already running as Administrator.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cmd.exe /c "$(wslpath -w "${SCRIPT_DIR}/ghidra-wsl2-portproxy.bat")"
