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
export GHIDRA_MCP_SCRIPTS_DIR="$HOME/.config/ghidra/ghidra_12.1_PUBLIC/Extensions/MyExt/ghidra_scripts"
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
- Auto-creates `.venv` on first run; refreshes only when `requirements.txt` changes
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

### 3. `build-install.sh` — build and install in one step

Thin wrapper over `ghidra-mcp-setup.sh --deploy`. Resolves
`GHIDRA_INSTALL_DIR` (env → `~/soft/ghidra/ghidra`) and builds with Maven
(preferred) or Gradle (auto-bootstrapped if neither is installed).

```sh
./build-install.sh                    # build + install to local Ghidra
./build-install.sh --build-tool=gradle
```

### 4. Bug fixes

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
