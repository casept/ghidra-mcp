#!/usr/bin/env bash
# build-install.sh — Convenience entry point for the most common case:
# build the GhidraMCP extension and install it into the local Ghidra.
#
# This is a thin shim over ghidra-mcp-setup.sh --deploy. The setup script
# itself handles all the heavy lifting (build-tool selection, dependency
# bootstrap, Python venv, etc.). This wrapper just:
#
#   1. Resolves GHIDRA_INSTALL_DIR (env > default ~/soft/ghidra/ghidra).
#   2. Invokes ghidra-mcp-setup.sh --deploy with sane defaults.
#
# Build-system selection (handled by ghidra-mcp-setup.sh):
#
#   • If `mvn` is on PATH → build with Maven (default preference).
#   • Else if `./gradlew` or `gradle` is available → build with Gradle.
#   • Else → download Gradle into .gradle-bootstrap/ on first run.
#
# Override with --build-tool=mvn or --build-tool=gradle (forwarded to setup).
#
# Examples:
#   ./build-install.sh                                 # auto-pick build tool
#   ./build-install.sh --build-tool=gradle             # force Gradle
#   GHIDRA_INSTALL_DIR=/opt/ghidra ./build-install.sh  # override Ghidra path

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

: "${GHIDRA_INSTALL_DIR:=$HOME/soft/ghidra/ghidra}"
export GHIDRA_INSTALL_DIR

exec "$SCRIPT_DIR/ghidra-mcp-setup.sh" \
    --deploy \
    --ghidra-path "$GHIDRA_INSTALL_DIR" \
    --use-venv \
    --skip-restart \
    "$@"
