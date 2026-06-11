#!/usr/bin/env bash
# bridge_mcp_ghidra.sh — Launch the GhidraMCP Python bridge in stdio mode.
#
# Designed to be invoked by MCP clients (Claude Desktop, mcp-inspector, etc.)
# as the configured server command. The bridge speaks MCP over stdin/stdout, so
# this wrapper:
#   • does NOT print to stdout (every log message goes to stderr)
#   • uses the project-local .venv if it exists, falls back to system python
#   • auto-creates .venv on first run if missing
#   • installs/refreshes requirements.txt only when needed (idempotent, fast)
#   • forwards every CLI flag to bridge_mcp_ghidra.py untouched
#
# Usage (manual):
#   ./bridge_mcp_ghidra.sh
#   ./bridge_mcp_ghidra.sh --lazy --default-groups listing,function
#
# MCP client config (e.g. Claude Desktop / Goose):
#   {
#     "mcpServers": {
#       "ghidra": {
#         "command": "/abs/path/to/ghidra-mcp/bridge_mcp_ghidra.sh"
#       }
#     }
#   }
#
# Environment overrides:
#   GHIDRA_MCP_VENV     — path to venv (default: <repo>/.venv)
#   GHIDRA_MCP_PYTHON   — python executable (skip venv logic if set)
#   GHIDRA_MCP_NO_INSTALL=1 — do not auto-install requirements.txt
#   GHIDRA_DEBUGGER_URL — forwarded to the bridge for debugger proxy tools

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

BRIDGE_PY="${SCRIPT_DIR}/bridge_mcp_ghidra.py"
REQUIREMENTS="${SCRIPT_DIR}/requirements.txt"

# All wrapper logging goes to stderr — stdout is reserved for the MCP protocol.
log()  { printf '[bridge_mcp_ghidra] %s\n' "$*" >&2; }
die()  { printf '[bridge_mcp_ghidra] ERROR: %s\n' "$*" >&2; exit 1; }

[[ -f "$BRIDGE_PY" ]] || die "bridge_mcp_ghidra.py not found at $BRIDGE_PY"

# --- Resolve Python executable ----------------------------------------------
PYTHON_BIN="${GHIDRA_MCP_PYTHON:-}"

if [[ -z "$PYTHON_BIN" ]]; then
    VENV_DIR="${GHIDRA_MCP_VENV:-${SCRIPT_DIR}/.venv}"

    if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
        # No venv — try to create one.
        SYS_PY=""
        for cand in python3 python; do
            if command -v "$cand" >/dev/null 2>&1; then
                SYS_PY="$cand"; break
            fi
        done
        [[ -n "$SYS_PY" ]] || die "No python interpreter found on PATH"

        log "Creating virtualenv at ${VENV_DIR} (one-time)"
        if ! "$SYS_PY" -m venv "$VENV_DIR" >&2; then
            die "Failed to create venv. Install python3-venv (apt install python3-venv) or set GHIDRA_MCP_PYTHON."
        fi
    fi

    PYTHON_BIN="${VENV_DIR}/bin/python"
fi

[[ -x "$PYTHON_BIN" ]] || die "Python executable not found or not executable: $PYTHON_BIN"

# --- Ensure dependencies ----------------------------------------------------
if [[ "${GHIDRA_MCP_NO_INSTALL:-0}" != "1" && -f "$REQUIREMENTS" ]]; then
    # Cheap check first: is `mcp` importable? If yes, skip the pip call entirely
    # to keep startup latency low (MCP clients spawn this on every connect).
    if ! "$PYTHON_BIN" -c 'import mcp, requests' >/dev/null 2>&1; then
        log "Installing Python requirements (first run)..."
        "$PYTHON_BIN" -m pip install --quiet --upgrade pip >&2 || true
        "$PYTHON_BIN" -m pip install --quiet -r "$REQUIREMENTS" >&2 \
            || die "pip install -r requirements.txt failed"
    fi
fi

# --- Hand off to the bridge -------------------------------------------------
# TCP by default: skip UDS socket scan and use TCP port auto-discovery.
# Works for single instance (port 8089) and multi-instance (auto-scan 8089+).
# Override with GHIDRA_MCP_DISABLE_UDS=0 to re-enable UDS discovery.
export GHIDRA_MCP_DISABLE_UDS="${GHIDRA_MCP_DISABLE_UDS:-1}"

# `--transport stdio` is already the bridge's default, but pass it explicitly
# so behaviour is unambiguous regardless of future default changes.
# `exec` replaces this shell with python so signals propagate cleanly to the
# MCP client (Ctrl-C, SIGTERM on disconnect, etc.).
exec "$PYTHON_BIN" "$BRIDGE_PY" --transport stdio "$@"
