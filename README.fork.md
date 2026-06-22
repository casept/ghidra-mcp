# README.fork.md — fork changes over bethington/ghidra-mcp

This fork is maintained at `re/ghidra-mcp/` inside the
[olha-ai-revers](https://gitlab.s-o.one/olha-team/olha-ai-revers) workspace.

Upstream: https://github.com/bethington/ghidra-mcp  
Upstream remote alias: `upstream`

## What this fork adds

### 1. `GHIDRA_MCP_SCRIPTS_DIR` env var (SecurityConfig + ProgramScriptService)

`run_script_inline` writes a temporary `.java` file to a local directory, then
compiles and runs it via Ghidra's OSGi bundle system. The directory must be an
active OSGi source bundle (registered in Ghidra's Script Manager).

By default the directory is `~/ghidra_scripts/`, which requires a one-time
manual activation in Ghidra's Script Manager UI. Setting
`GHIDRA_MCP_SCRIPTS_DIR` lets you point to any pre-activated directory — in
particular an extension's `ghidra_scripts/` subdir, which is
**automatically active** on every Ghidra start without any UI step.

**Usage:**
```sh
# Set in the environment that launches Ghidra (not the Python bridge):
export GHIDRA_MCP_ALLOW_SCRIPTS=1
export GHIDRA_MCP_SCRIPTS_DIR="$HOME/.config/ghidra/ghidra_12.1.2_PUBLIC/Extensions/MyExt/ghidra_scripts"
./ghidraRun
```

`mk/ghidra-run.sh` in the workspace derives the path automatically from the
installed Ghidra version — no hardcoded version strings.

### 2. `bridge_mcp_ghidra.sh` — stdio MCP launcher

A Bash wrapper that launches the Python bridge in `stdio` mode (MCP over
stdin/stdout). Designed to be the `command:` entry in MCP client configs
(Claude Desktop, Goose, Copilot CLI, mcp-inspector).

Features:
- Logs only to stderr — stdout is clean for MCP
- Auto-creates `.venv` on first run; re-runs `pip install` when core imports fail
- Falls back to system Python if no `.venv` exists
- Forwards all CLI flags to `bridge_mcp_ghidra.py` unchanged

**MCP client config example:**
```json
{
  "mcpServers": {
    "ghidra": {
      "command": "/abs/path/to/re/ghidra-mcp/bridge_mcp_ghidra.sh"
    }
  }
}
```

**Environment overrides:**
| Variable | Default | Description |
|----------|---------|-------------|
| `GHIDRA_MCP_VENV` | `<repo>/.venv` | Path to Python venv |
| `GHIDRA_MCP_PYTHON` | — | Explicit Python executable (skip venv) |
| `GHIDRA_MCP_NO_INSTALL=1` | — | Skip `pip install` on startup |
| `GHIDRA_DEBUGGER_URL` | — | Forwarded to bridge (debugger proxy tools) |

### 3. "Allow Script Execution" GUI Tool Option

In the GUI plugin, script execution can be toggled via
**Edit > Tool Options > GhidraMCP HTTP Server > Allow Script Execution**
without restarting Ghidra or setting an env var. The checkbox is OR-combined
with `GHIDRA_MCP_ALLOW_SCRIPTS` — either one enables scripts. Headless
deployments use the env var exclusively.

### 4. `--ghidra-address` bridge CLI flag

Allows the Python bridge to connect to a specific Ghidra instance instead of
relying on UDS auto-discovery:

```sh
bridge_mcp_ghidra.py --ghidra-address tcp://host:8089
bridge_mcp_ghidra.py --ghidra-address unix:///path/to/socket
```

Accepted schemes: `unix://`, `tcp://`, `http://`, `https://`.

### 5. Shared Ghidra Server MCP tools (`server` tool group)

17 MCP tools for working with a shared Ghidra Server, exposed via
`ProjectVersionControlService` (GUI mode, DomainFile-based) and
`SharedRepositoryService` (headless mode, standalone RepositoryAdapter).

**GUI mode** operates on the open project's DomainFile objects — real
checkin/checkout/undo works. **Headless mode** uses a standalone server
connection for read and admin operations.

| Tool | Description |
|------|-------------|
| `server_connect` | Connection status (GUI: project-based, no separate connect needed) |
| `server_disconnect` | Disconnect (GUI: no-op) |
| `server_status` | Project status, shared flag, server info, verified health |
| `server_reconnect` | Reconnect after SSH tunnel drop (calls RepositoryAdapter.connect()) |
| `server_repositories` | List all repos on the Ghidra Server |
| `server_repository_files` | Browse project folder/file tree |
| `server_repository_file` | File metadata (version, checkout status) |
| `server_repository_create` | Create new repo (headless only) |
| `server_version_control_checkout` | Check out a file (DomainFile.checkout in GUI) |
| `server_version_control_checkin` | Check in a file (DomainFile.checkin in GUI — persists to server) |
| `server_version_control_undo_checkout` | Undo checkout |
| `server_version_control_add` | Add file to version control |
| `server_version_history` | File version history (all versions with user, comment, date) |
| `server_checkouts` | List checked-out files in a folder |
| `server_admin_users` | List server users (headless only) |
| `server_admin_set_permissions` | Set repo access level (headless only) |
| `server_admin_terminate_checkout` | Force-kill a checkout |
| `server_admin_terminate_all_checkouts` | Recursive terminate in folder |

### 6. Bug fixes

**`fix: improve param resolution in resolveProgram() and AnnotationScanner`**

- `ProgramProvider.resolveProgram()`: when a program name was explicitly
  specified but not found, the function silently fell back to
  `getCurrentProgram()`. Write operations (rename, comment, type changes) would
  target the active program instead of the intended one with no error. Now
  returns `null` so `getProgramOrError()` reports an explicit error listing
  available programs.

- `AnnotationScanner.resolveParam()`: when a `@Param(source=QUERY)` parameter
  was missing from the query string on a POST request, the value was silently
  lost. The Python bridge (and other MCP clients) send all params in the JSON
  body. Added a fallback: if the query param is absent, look in the JSON body.
  Affects all POST endpoints that use `@Param(source=QUERY)` (e.g. `program`).

**`fix: Remove forced Hungarian notation, global naming conventions`**

`NamingConventions.java` enforced Ghidra-style Hungarian prefixes on variable
names passed to rename tools, rejecting valid names from AI agents. Enforcement
removed; names are accepted as-is.

## Building

From the parent project (olha-ai-reverse):
```sh
make ghidra-plugins   # builds + installs ghidra-mcp and olha-ghidra-scripts
```

Standalone (requires nix):
```sh
nix develop --command ./gradlew buildExtension -PGHIDRA_INSTALL_DIR=/path/to/ghidra
```

## Key environment variables

All variables must be set in the JVM environment (the Ghidra process):

| Variable | Default | Description |
|----------|---------|-------------|
| `GHIDRA_MCP_ALLOW_SCRIPTS` | `0` | Set to `1` to enable `run_script_inline` |
| `GHIDRA_MCP_SCRIPTS_DIR` | `~/ghidra_scripts` | Directory for inline script temp files |
| `GHIDRA_MCP_AUTH_TOKEN` | — | Bearer token for HTTP authentication |
| `GHIDRA_MCP_FILE_ROOT` | — | Restrict file access to this directory |

## Upstream sync

```sh
cd re/ghidra-mcp
git fetch upstream
git log upstream/main..HEAD --oneline   # our commits
git log HEAD..upstream/main --oneline   # upstream-only commits
```
