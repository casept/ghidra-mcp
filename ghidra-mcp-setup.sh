#!/usr/bin/env bash
# GhidraMCP Deployment Script for Linux (Ubuntu/Debian)
# Automatically builds, installs, and configures the GhidraMCP plugin
# Target: Ghidra 12.0.3
#
# Usage:
#   ./ghidra-mcp-setup.sh --deploy --ghidra-path /opt/ghidra_12.0.3_PUBLIC
#   ./ghidra-mcp-setup.sh --setup-deps --ghidra-path /opt/ghidra_12.0.3_PUBLIC
#   ./ghidra-mcp-setup.sh --build-only
#   ./ghidra-mcp-setup.sh --clean
#   ./ghidra-mcp-setup.sh --preflight --ghidra-path /opt/ghidra_12.0.3_PUBLIC
#   ./ghidra-mcp-setup.sh --help

set -euo pipefail

# ============================================================================
# Color output functions
# ============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
GRAY='\033[0;37m'
NC='\033[0m'

log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

# ============================================================================
# Configuration
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_GHIDRA_VERSION="12.0.3"
PLUGIN_VERSION="5.2.0"

# Parameters (defaults)
ACTION=""
GHIDRA_PATH=""
GHIDRA_VERSION=""
STRICT_PREFLIGHT=false
NO_AUTO_PREREQS=false
SKIP_BUILD=false
SKIP_RESTART=false
DRY_RUN=false
FORCE=false
VERBOSE=false
USE_VENV=false
BUILD_TOOL=""        # auto | mvn | gradle (auto-detected if empty)

# Pinned Gradle version used to bootstrap a local Gradle if neither mvn nor
# any gradle is available. Must satisfy Ghidra's application.gradle.min (8.5
# for Ghidra 12.x). Override with $GRADLE_BOOTSTRAP_VERSION.
GRADLE_BOOTSTRAP_VERSION="${GRADLE_BOOTSTRAP_VERSION:-8.10.2}"

# ============================================================================
# Usage / Help
# ============================================================================
show_usage() {
    echo ""
    echo -e "${MAGENTA}GhidraMCP Setup for Linux - Usage${NC}"
    echo ""
    echo "Actions (choose one):"
    echo "  --setup-deps       Install required Ghidra JARs into local Maven repository"
    echo "  --build-only       Build project artifacts only"
    echo "  --deploy           Full end-user flow: Python deps + Maven deps + build + deploy (default)"
    echo "  --clean            Remove build output, local extension cache, and local Ghidra Maven jars"
    echo "  --preflight        Validate environment and prerequisites without making changes"
    echo ""
    echo "Common options:"
    echo "  --ghidra-path PATH    Path to Ghidra install (e.g., /opt/ghidra_12.0.3_PUBLIC)"
    echo "  --ghidra-version VER  Explicit Ghidra version (must match pom.xml/path version)"
    echo "  --strict-preflight    Fail preflight on network checks (Maven Central/PyPI reachability)"
    echo "  --no-auto-prereqs     Disable automatic prerequisite setup during deploy"
    echo "  --skip-build          Deploy existing artifact without rebuilding"
    echo "  --skip-restart        Do not restart Ghidra after deployment"
    echo "  --force               Reinstall dependencies even if already present"
    echo "  --dry-run             Print actions without executing commands"
    echo "  --verbose             Verbose logging"
    echo "  --use-venv            Install Python dependencies into a local .venv instead of system Python"
    echo "  --build-tool TOOL     Build tool to use: mvn | gradle | auto (default: auto)"
    echo "                        - auto: prefer mvn if installed, else system gradle, else"
    echo "                          ./gradlew, else download Gradle locally to .gradle-bootstrap/"
    echo "  --help, -h            Show this help text"
    echo ""
    echo "Examples:"
    echo "  ./ghidra-mcp-setup.sh --deploy --ghidra-path /opt/ghidra_12.0.3_PUBLIC"
    echo "  ./ghidra-mcp-setup.sh --deploy --ghidra-path /opt/ghidra_12.0.3_PUBLIC --use-venv"
    echo "  ./ghidra-mcp-setup.sh --setup-deps --ghidra-path /opt/ghidra_12.0.3_PUBLIC"
    echo "  ./ghidra-mcp-setup.sh --preflight --ghidra-path /opt/ghidra_12.0.3_PUBLIC"
    echo "  ./ghidra-mcp-setup.sh --build-only"
    echo "  ./ghidra-mcp-setup.sh --clean"
    echo ""
}

# ============================================================================
# Argument parsing
# ============================================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        --setup-deps)       ACTION="setup-deps"; shift ;;
        --build-only)       ACTION="build-only"; shift ;;
        --deploy)           ACTION="deploy"; shift ;;
        --clean)            ACTION="clean"; shift ;;
        --preflight)        ACTION="preflight"; shift ;;
        --ghidra-path)      GHIDRA_PATH="$2"; shift 2 ;;
        --ghidra-version)   GHIDRA_VERSION="$2"; shift 2 ;;
        --strict-preflight) STRICT_PREFLIGHT=true; shift ;;
        --no-auto-prereqs)  NO_AUTO_PREREQS=true; shift ;;
        --skip-build)       SKIP_BUILD=true; shift ;;
        --skip-restart)     SKIP_RESTART=true; shift ;;
        --force)            FORCE=true; shift ;;
        --dry-run)          DRY_RUN=true; shift ;;
        --verbose)          VERBOSE=true; shift ;;
        --use-venv)         USE_VENV=true; shift ;;
        --build-tool)
            BUILD_TOOL="$2"; shift 2
            case "$BUILD_TOOL" in
                mvn|maven)  BUILD_TOOL="mvn" ;;
                gradle)     BUILD_TOOL="gradle" ;;
                auto|"")    BUILD_TOOL="" ;;
                *) log_error "Invalid --build-tool: $BUILD_TOOL (expected mvn|gradle|auto)"; exit 1 ;;
            esac
            ;;
        --help|-h)          show_usage; exit 0 ;;
        *)
            log_error "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

# ============================================================================
# Utility functions
# ============================================================================

verbose_log() {
    if $VERBOSE; then
        log_info "$1"
    fi
}

# Extract ghidra.version from pom.xml
get_pom_ghidra_version() {
    local pom_path="${SCRIPT_DIR}/pom.xml"
    if [[ ! -f "$pom_path" ]]; then
        echo ""
        return
    fi
    # Parse XML with grep/sed (no dependency on xmllint)
    local version
    version=$(grep -oP '<ghidra\.version>\K[^<]+' "$pom_path" 2>/dev/null || echo "")
    echo "$version"
}

# Extract version from Ghidra's application.properties
get_version_from_ghidra_properties() {
    local ghidra_path="$1"
    if [[ -z "$ghidra_path" ]]; then echo ""; return; fi

    local props_path="${ghidra_path}/Ghidra/application.properties"
    if [[ ! -f "$props_path" ]]; then
        echo ""
        return
    fi

    local version
    version=$(grep -E '^\s*application\.version\s*=' "$props_path" 2>/dev/null \
        | head -1 | sed 's/.*=\s*//' | tr -d '[:space:]')
    echo "$version"
}

# Extract version from Ghidra path name (e.g., ghidra_12.0.3_PUBLIC)
get_version_from_ghidra_path() {
    local path_value="$1"
    if [[ -z "$path_value" ]]; then echo ""; return; fi

    if [[ "$path_value" =~ ghidra_([0-9]+(\.[0-9]+){1,3})_PUBLIC ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo ""
    fi
}

# Find Gradle wrapper
get_gradle_path() {
    local wrapper="${SCRIPT_DIR}/gradlew"
    if [[ -x "$wrapper" ]]; then
        echo "$wrapper"
    else
        echo ""
    fi
}

# Find Maven executable (PATH first, then well-known locations)
get_maven_path() {
    local mvn_path
    mvn_path=$(command -v mvn 2>/dev/null || true)
    if [[ -n "$mvn_path" ]]; then
        echo "$mvn_path"
        return
    fi
    local common_paths=(
        "$HOME/tools/apache-maven-3.9.6/bin/mvn"
        "/opt/maven/bin/mvn"
        "/usr/local/maven/bin/mvn"
        "/usr/share/maven/bin/mvn"
    )
    for p in "${common_paths[@]}"; do
        if [[ -x "$p" ]]; then
            echo "$p"
            return
        fi
    done
    echo ""
}

# Find any usable system Gradle on PATH (returns "" if none)
get_system_gradle() {
    command -v gradle 2>/dev/null || echo ""
}

# Bootstrap a project-local Gradle distribution (used only when neither mvn,
# nor system gradle, nor a committed wrapper is available). The distribution
# is unpacked into .gradle-bootstrap/ and reused on subsequent runs.
# Echoes the absolute path to the gradle binary, or "" on failure.
install_local_gradle() {
    local boot_root="${SCRIPT_DIR}/.gradle-bootstrap"
    local boot_bin="${boot_root}/gradle-${GRADLE_BOOTSTRAP_VERSION}/bin/gradle"

    if [[ -x "$boot_bin" ]]; then
        echo "$boot_bin"
        return 0
    fi

    if ! command -v curl >/dev/null 2>&1; then
        log_error "curl is required to download Gradle"; return 1
    fi
    if ! command -v unzip >/dev/null 2>&1; then
        log_error "unzip is required to extract Gradle"; return 1
    fi

    mkdir -p "$boot_root"
    local zip_url="https://services.gradle.org/distributions/gradle-${GRADLE_BOOTSTRAP_VERSION}-bin.zip"
    local zip_path="${boot_root}/gradle-${GRADLE_BOOTSTRAP_VERSION}-bin.zip"

    log_info "Downloading Gradle ${GRADLE_BOOTSTRAP_VERSION} → ${zip_path}" >&2
    if ! curl -fsSL --retry 3 -o "$zip_path" "$zip_url"; then
        log_error "Failed to download $zip_url"; return 1
    fi
    log_info "Extracting Gradle distribution..." >&2
    unzip -q -o "$zip_path" -d "$boot_root"
    rm -f "$zip_path"

    if [[ ! -x "$boot_bin" ]]; then
        log_error "Bootstrap Gradle binary missing after extract: $boot_bin"
        return 1
    fi
    echo "$boot_bin"
}

# Try to fetch the gradle-wrapper.jar from the pinned Gradle distribution
# (so ./gradlew works on a fresh clone where the wrapper jar wasn't committed).
# Idempotent. Returns 0 if wrapper is now usable, 1 otherwise.
ensure_gradle_wrapper_files() {
    local wrapper_jar="${SCRIPT_DIR}/gradle/wrapper/gradle-wrapper.jar"
    if [[ -f "$wrapper_jar" && -x "${SCRIPT_DIR}/gradlew" ]]; then
        return 0
    fi

    log_info "Gradle wrapper files missing — generating via local Gradle..." >&2
    local boot_gradle
    boot_gradle=$(get_system_gradle)
    if [[ -z "$boot_gradle" ]]; then
        boot_gradle=$(install_local_gradle) || return 1
    fi

    GHIDRA_INSTALL_DIR="${GHIDRA_PATH:-${GHIDRA_INSTALL_DIR:-}}" \
        "$boot_gradle" --no-daemon -q wrapper \
            --gradle-version "$GRADLE_BOOTSTRAP_VERSION" \
            --distribution-type bin \
        || { log_error "gradle wrapper task failed"; return 1; }

    [[ -x "${SCRIPT_DIR}/gradlew" ]] || { log_error "gradlew was not created"; return 1; }
    log_success "Gradle wrapper generated"
    return 0
}

# Resolve which build tool to use. Honors $BUILD_TOOL; otherwise auto-detects.
# Sets two globals as side effects (cannot use stdout — child subshell would
# discard the RESOLVED_BUILD_BIN write):
#   RESOLVED_BUILD_TOOL  → "mvn" or "gradle"
#   RESOLVED_BUILD_BIN   → absolute path to the build tool executable
# Returns 0 on success, 1 on failure.
RESOLVED_BUILD_TOOL=""
RESOLVED_BUILD_BIN=""
select_build_tool() {
    RESOLVED_BUILD_TOOL=""
    RESOLVED_BUILD_BIN=""
    local choice="$BUILD_TOOL"

    # Explicit: mvn
    if [[ "$choice" == "mvn" ]]; then
        local mvn; mvn=$(get_maven_path)
        if [[ -z "$mvn" ]]; then
            log_error "--build-tool=mvn but Maven not found. Install with: sudo apt install maven"
            return 1
        fi
        RESOLVED_BUILD_TOOL="mvn"; RESOLVED_BUILD_BIN="$mvn"; return 0
    fi

    # Explicit: gradle
    if [[ "$choice" == "gradle" ]]; then
        local g
        g=$(get_gradle_path)        # ./gradlew first
        [[ -z "$g" ]] && g=$(get_system_gradle)
        if [[ -z "$g" ]]; then
            if ensure_gradle_wrapper_files; then
                g=$(get_gradle_path)
            else
                g=$(install_local_gradle) || return 1
            fi
        fi
        if [[ -z "$g" ]]; then
            log_error "--build-tool=gradle but no usable Gradle found"; return 1
        fi
        RESOLVED_BUILD_TOOL="gradle"; RESOLVED_BUILD_BIN="$g"; return 0
    fi

    # auto: prefer mvn (matches pre-hack default), then fall back to gradle
    local mvn; mvn=$(get_maven_path)
    if [[ -n "$mvn" ]]; then
        RESOLVED_BUILD_TOOL="mvn"; RESOLVED_BUILD_BIN="$mvn"; return 0
    fi

    log_info "Maven not found — falling back to Gradle"
    local g
    g=$(get_gradle_path)
    [[ -z "$g" ]] && g=$(get_system_gradle)
    if [[ -z "$g" ]]; then
        if ensure_gradle_wrapper_files; then
            g=$(get_gradle_path)
        else
            g=$(install_local_gradle) || return 1
        fi
    fi
    if [[ -z "$g" ]]; then
        log_error "No usable build tool. Install Maven or Gradle."
        return 1
    fi
    RESOLVED_BUILD_TOOL="gradle"; RESOLVED_BUILD_BIN="$g"; return 0
}

# Find Python executable
get_python_command() {
    for cmd in python3 python; do
        if command -v "$cmd" &>/dev/null; then
            echo "$cmd"
            return
        fi
    done
    echo ""
}

# Test write access to a directory
test_write_access() {
    local path_to_test="$1"
    if [[ ! -d "$path_to_test" ]]; then
        mkdir -p "$path_to_test" 2>/dev/null || return 1
    fi
    local probe="${path_to_test}/.ghidra-mcp-write-test"
    echo "ok" > "$probe" 2>/dev/null && rm -f "$probe" 2>/dev/null
    return $?
}

# Find Ghidra processes (match the Ghidra JVM class name in command line)
get_ghidra_pids() {
    # Match only the Java class name pattern (ghidra.GhidraRun or ghidra.GhidraLauncher)
    # to avoid false positives from editors/file managers viewing Ghidra files
    pgrep -f 'ghidra\.Ghidra(Run|Launcher)' 2>/dev/null || true
}

# Close Ghidra processes
close_ghidra() {
    local pids
    pids=$(get_ghidra_pids)
    if [[ -z "$pids" ]]; then
        return 1  # No Ghidra processes found
    fi

    local count
    count=$(echo "$pids" | wc -w)
    log_info "Detected ${count} Ghidra process(es) running"

    for pid in $pids; do
        log_info "Sending SIGTERM to Ghidra process $pid..."
        kill "$pid" 2>/dev/null || true
    done

    # Wait up to 5 seconds for graceful shutdown
    local waited=0
    while [[ $waited -lt 5 ]]; do
        pids=$(get_ghidra_pids)
        if [[ -z "$pids" ]]; then
            log_success "Ghidra processes closed gracefully"
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done

    # Force kill remaining processes
    pids=$(get_ghidra_pids)
    if [[ -n "$pids" ]]; then
        if $FORCE; then
            log_warning "Force killing remaining Ghidra processes..."
            for pid in $pids; do
                kill -9 "$pid" 2>/dev/null || true
            done
            sleep 1
            log_success "Ghidra processes force killed"
        else
            log_warning "Some Ghidra processes did not close gracefully. Use --force to terminate."
        fi
    fi

    return 0
}

# Run a command with dry-run support
run_cmd() {
    local description="$1"
    shift

    if $DRY_RUN; then
        log_info "[DRY RUN] $description"
        echo "          $*"
        return 0
    fi

    verbose_log "$description"
    verbose_log "          $*"

    "$@"
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log_error "Command failed (exit code $exit_code): $*"
        return $exit_code
    fi
    return 0
}

# ============================================================================
# Core functions
# ============================================================================

validate_ghidra_jars() {
    local resolved_ghidra_path="$1"

    local -a required_jars=(
        "Ghidra/Features/Base/lib/Base.jar"
        "Ghidra/Features/Decompiler/lib/Decompiler.jar"
        "Ghidra/Framework/Docking/lib/Docking.jar"
        "Ghidra/Framework/Generic/lib/Generic.jar"
        "Ghidra/Framework/Project/lib/Project.jar"
        "Ghidra/Framework/SoftwareModeling/lib/SoftwareModeling.jar"
        "Ghidra/Framework/Utility/lib/Utility.jar"
        "Ghidra/Framework/Gui/lib/Gui.jar"
        "Ghidra/Framework/FileSystem/lib/FileSystem.jar"
        "Ghidra/Framework/Graph/lib/Graph.jar"
        "Ghidra/Framework/DB/lib/DB.jar"
        "Ghidra/Framework/Emulation/lib/Emulation.jar"
        "Ghidra/Framework/Help/lib/Help.jar"
        "Ghidra/Debug/Debugger-api/lib/Debugger-api.jar"
        "Ghidra/Debug/Framework-TraceModeling/lib/Framework-TraceModeling.jar"
        "Ghidra/Debug/Debugger-rmi-trace/lib/Debugger-rmi-trace.jar"
    )

    for rel in "${required_jars[@]}"; do
        if [[ ! -f "${resolved_ghidra_path}/${rel}" ]]; then
            log_error "Missing Ghidra JAR: ${resolved_ghidra_path}/${rel}"
            return 1
        fi
    done

    log_success "All required Ghidra JARs present."
}

# Install Ghidra JARs into the local Maven repository (~/.m2/repository).
# Only used when the build tool is Maven; Gradle reads JARs directly.
install_ghidra_dependencies() {
    local resolved_ghidra_path="$1"
    local maven_path="$2"

    local -a artifact_names=(
        "Base" "Decompiler" "Docking" "Generic" "Project"
        "SoftwareModeling" "Utility" "Gui" "FileSystem" "Graph"
        "DB" "Emulation" "PDB" "FunctionID" "Help"
        "Debugger-api" "Framework-TraceModeling" "Debugger-rmi-trace"
    )
    local -a artifact_paths=(
        "Ghidra/Features/Base/lib/Base.jar"
        "Ghidra/Features/Decompiler/lib/Decompiler.jar"
        "Ghidra/Framework/Docking/lib/Docking.jar"
        "Ghidra/Framework/Generic/lib/Generic.jar"
        "Ghidra/Framework/Project/lib/Project.jar"
        "Ghidra/Framework/SoftwareModeling/lib/SoftwareModeling.jar"
        "Ghidra/Framework/Utility/lib/Utility.jar"
        "Ghidra/Framework/Gui/lib/Gui.jar"
        "Ghidra/Framework/FileSystem/lib/FileSystem.jar"
        "Ghidra/Framework/Graph/lib/Graph.jar"
        "Ghidra/Framework/DB/lib/DB.jar"
        "Ghidra/Framework/Emulation/lib/Emulation.jar"
        "Ghidra/Features/PDB/lib/PDB.jar"
        "Ghidra/Features/FunctionID/lib/FunctionID.jar"
        "Ghidra/Framework/Help/lib/Help.jar"
        "Ghidra/Debug/Debugger-api/lib/Debugger-api.jar"
        "Ghidra/Debug/Framework-TraceModeling/lib/Framework-TraceModeling.jar"
        "Ghidra/Debug/Debugger-rmi-trace/lib/Debugger-rmi-trace.jar"
    )

    local quiet_flag=""
    if ! $VERBOSE; then quiet_flag="-q"; fi

    for i in "${!artifact_names[@]}"; do
        local artifact="${artifact_names[$i]}"
        local rel_path="${artifact_paths[$i]}"
        local jar_path="${resolved_ghidra_path}/${rel_path}"
        if [[ ! -f "$jar_path" ]]; then
            log_error "Missing JAR: $jar_path"
            return 1
        fi
        local m2_jar="$HOME/.m2/repository/ghidra/${artifact}/${GHIDRA_VERSION}/${artifact}-${GHIDRA_VERSION}.jar"
        if [[ -f "$m2_jar" ]] && ! $FORCE; then
            verbose_log "Already installed, skipping: ${artifact}"
            continue
        fi
        local -a install_args=()
        [[ -n "$quiet_flag" ]] && install_args+=("$quiet_flag")
        install_args+=(
            "install:install-file"
            "-Dfile=${jar_path}"
            "-DgroupId=ghidra"
            "-DartifactId=${artifact}"
            "-Dversion=${GHIDRA_VERSION}"
            "-Dpackaging=jar"
            "-DgeneratePom=true"
        )
        run_cmd "Installing Ghidra dependency: ${artifact}" "$maven_path" "${install_args[@]}"
    done
    log_success "Ghidra dependencies installed in local Maven repository."
}

# Run the actual build using whichever tool select_build_tool() picks.
# Builds the extension ZIP and leaves it in either target/ (mvn) or dist/ (gradle).
do_build() {
    select_build_tool || {
        log_error "No usable build tool. Install Maven or Gradle, or allow internet access for bootstrap."
        return 1
    }
    log_info "Using build tool: ${RESOLVED_BUILD_TOOL} (${RESOLVED_BUILD_BIN})"

    if [[ "$RESOLVED_BUILD_TOOL" == "mvn" ]]; then
        # Maven path requires Ghidra deps to be installed in local m2 first.
        if [[ -n "$GHIDRA_PATH" && -f "${GHIDRA_PATH}/ghidraRun" ]]; then
            install_ghidra_dependencies "$GHIDRA_PATH" "$RESOLVED_BUILD_BIN" \
                || { log_error "Ghidra dependency install failed"; return 1; }
        fi
        run_cmd "Building GhidraMCP extension (Maven)" \
            "$RESOLVED_BUILD_BIN" clean package assembly:single -DskipTests
    else
        if [[ -z "${GHIDRA_PATH:-}" ]]; then
            log_error "GHIDRA_PATH is required for Gradle build. Pass --ghidra-path or set GHIDRA_PATH/GHIDRA_INSTALL_DIR."
            return 1
        fi
        run_cmd "Building GhidraMCP extension (Gradle)" env \
            GRADLE_USER_HOME="${SCRIPT_DIR}/.gradle-home" \
            GHIDRA_INSTALL_DIR="$GHIDRA_PATH" \
            "$RESOLVED_BUILD_BIN" buildExtension
    fi
}

invoke_clean_action() {
    # Remove build output (both Maven and Gradle locations)
    for build_dir in "${SCRIPT_DIR}/dist" "${SCRIPT_DIR}/target" \
                     "${SCRIPT_DIR}/.gradle-bootstrap" \
                     "${SCRIPT_DIR}/.gradle-home" \
                     "${SCRIPT_DIR}/build"; do
        if [[ -d "$build_dir" ]]; then
            if $DRY_RUN; then
                log_info "[DRY RUN] Would remove: $build_dir"
            else
                rm -rf "$build_dir"
                log_success "Removed: $(basename "$build_dir")"
            fi
        fi
    done

    # Remove GhidraMCP from user config extensions
    local ghidra_config_base="$HOME/.config/ghidra"
    if [[ -d "$ghidra_config_base" ]]; then
        for version_dir in "$ghidra_config_base"/ghidra_*; do
            if [[ -d "$version_dir" ]]; then
                local ext_path="${version_dir}/Extensions/GhidraMCP"
                if [[ -d "$ext_path" ]]; then
                    if $DRY_RUN; then
                        log_info "[DRY RUN] Would remove: $ext_path"
                    else
                        rm -rf "$ext_path"
                        log_info "Removed cached extension: $ext_path"
                    fi
                fi
            fi
        done
    fi

    # Also check legacy XDG path and ~/.ghidra
    for base_path in "$HOME/.ghidra" "${XDG_DATA_HOME:-$HOME/.local/share}/ghidra"; do
        if [[ -d "$base_path" ]]; then
            for version_dir in "$base_path"/ghidra_*; do
                if [[ -d "$version_dir" ]]; then
                    local ext_path="${version_dir}/Extensions/GhidraMCP"
                    if [[ -d "$ext_path" ]]; then
                        if $DRY_RUN; then
                            log_info "[DRY RUN] Would remove: $ext_path"
                        else
                            rm -rf "$ext_path"
                            log_info "Removed cached extension: $ext_path"
                        fi
                    fi
                fi
            done
        fi
    done

    # Remove Maven Ghidra dependency cache (legacy cleanup)
    local artifacts=(
        "Base" "Decompiler" "Docking" "Generic" "Project"
        "SoftwareModeling" "Utility" "Gui" "FileSystem" "Graph"
        "DB" "Emulation" "PDB" "FunctionID" "Help"
    )

    local m2_root="$HOME/.m2/repository/ghidra"
    local removed_m2=0
    for artifact in "${artifacts[@]}"; do
        local artifact_version_dir="${m2_root}/${artifact}/${GHIDRA_VERSION}"
        if [[ -d "$artifact_version_dir" ]]; then
            if $DRY_RUN; then
                log_info "[DRY RUN] Would remove: $artifact_version_dir"
            else
                rm -rf "$artifact_version_dir"
                removed_m2=$((removed_m2 + 1))
            fi
        fi
    done

    if [[ $removed_m2 -gt 0 ]]; then
        log_info "Removed ${removed_m2} legacy Maven Ghidra dependency folder(s)."
    fi

    log_success "Cleanup completed."
}

install_python_packages() {
    local requirements_path="${SCRIPT_DIR}/requirements.txt"
    if [[ ! -f "$requirements_path" ]]; then
        log_warning "requirements.txt not found, skipping Python dependency installation."
        return
    fi

    local python_cmd
    python_cmd=$(get_python_command)
    if [[ -z "$python_cmd" ]]; then
        log_error "Python executable not found on PATH"
        return 1
    fi

    if $USE_VENV; then
        local venv_dir="${SCRIPT_DIR}/.venv"

        if [[ ! -d "$venv_dir" ]]; then
            log_info "Creating Python virtual environment at: $venv_dir"
            run_cmd "Creating venv" "$python_cmd" -m venv "$venv_dir"
        else
            verbose_log "Using existing venv at: $venv_dir"
        fi

        local venv_pip="${venv_dir}/bin/pip"
        if [[ ! -x "$venv_pip" ]]; then
            log_error "venv pip not found at: $venv_pip"
            return 1
        fi

        local -a pip_args=("install")
        if ! $VERBOSE; then
            pip_args+=("-q" "--disable-pip-version-check")
        fi
        pip_args+=("-r" "$requirements_path")

        run_cmd "Installing Python dependencies into venv" "$venv_pip" "${pip_args[@]}"
        log_success "Python dependencies installed into venv: $venv_dir"
    else
        local -a pip_args=("-m" "pip" "install")
        if ! $VERBOSE; then
            pip_args+=("-q" "--disable-pip-version-check")
        fi
        pip_args+=("-r" "$requirements_path")

        run_cmd "Ensuring Python dependencies" "$python_cmd" "${pip_args[@]}"
        log_success "Python dependencies are ready."
    fi
}

invoke_preflight_checks() {
    local resolved_ghidra_path="$1"
    local resolved_ghidra_version="$2"
    local strict="${3:-false}"

    log_info "Running preflight checks..."
    local issues=()

    # Build tool — at least one of mvn / gradle / wrapper / system gradle must
    # be available, OR we must be able to download Gradle locally.
    local mvn_path; mvn_path=$(get_maven_path)
    local gradle_wrapper; gradle_wrapper=$(get_gradle_path)
    local sys_gradle; sys_gradle=$(get_system_gradle)
    if [[ -n "$mvn_path" ]]; then
        log_success "Maven found: $mvn_path"
    elif [[ -n "$gradle_wrapper" ]]; then
        log_success "Gradle wrapper found: $gradle_wrapper"
    elif [[ -n "$sys_gradle" ]]; then
        log_success "System Gradle found: $sys_gradle"
    else
        if command -v curl >/dev/null 2>&1 && command -v unzip >/dev/null 2>&1; then
            log_warning "No build tool found — Gradle ${GRADLE_BOOTSTRAP_VERSION} will be downloaded into .gradle-bootstrap/ on first build."
        else
            issues+=("No build tool found and curl/unzip unavailable to bootstrap Gradle. Install one of: maven, gradle, or curl+unzip.")
        fi
    fi
    if [[ -n "$BUILD_TOOL" ]]; then
        log_info "Build tool override: --build-tool=${BUILD_TOOL}"
    fi

    # Python + pip
    local python_cmd
    python_cmd=$(get_python_command)
    if [[ -z "$python_cmd" ]]; then
        issues+=("Python executable not found on PATH. Install with: sudo apt install python3 python3-pip")
    else
        log_success "Python found: $python_cmd"
        if $USE_VENV; then
            if ! "$python_cmd" -m venv --help &>/dev/null; then
                issues+=("Python venv module not available. Install with: sudo apt install python3-venv")
            else
                log_success "Python venv module is available."
            fi
        else
            if ! "$python_cmd" -m pip --version &>/dev/null; then
                issues+=("pip is not available. Install with: sudo apt install python3-pip")
            else
                log_success "pip is available."
            fi
        fi
    fi

    # Java
    if ! command -v java &>/dev/null; then
        issues+=("Java not found on PATH (JDK 21 recommended). Install with: sudo apt install openjdk-21-jdk")
    else
        log_success "Java found: $(command -v java)"
    fi

    # unzip
    if ! command -v unzip &>/dev/null; then
        issues+=("unzip not found. Install with: sudo apt install unzip")
    else
        log_success "unzip is available."
    fi

    # Ghidra layout and required jars
    if [[ ! -f "${resolved_ghidra_path}/ghidraRun" ]]; then
        issues+=("Ghidra executable not found at: ${resolved_ghidra_path}")
    else
        log_success "Ghidra path looks valid."
        local required_jars=(
            "Ghidra/Features/Base/lib/Base.jar"
            "Ghidra/Features/Decompiler/lib/Decompiler.jar"
            "Ghidra/Framework/Docking/lib/Docking.jar"
            "Ghidra/Framework/Generic/lib/Generic.jar"
            "Ghidra/Framework/Project/lib/Project.jar"
            "Ghidra/Framework/SoftwareModeling/lib/SoftwareModeling.jar"
            "Ghidra/Framework/Utility/lib/Utility.jar"
            "Ghidra/Framework/Gui/lib/Gui.jar"
            "Ghidra/Framework/FileSystem/lib/FileSystem.jar"
            "Ghidra/Framework/Graph/lib/Graph.jar"
            "Ghidra/Framework/DB/lib/DB.jar"
            "Ghidra/Framework/Emulation/lib/Emulation.jar"
            "Ghidra/Features/PDB/lib/PDB.jar"
            "Ghidra/Features/FunctionID/lib/FunctionID.jar"
            "Ghidra/Framework/Help/lib/Help.jar"
        )
        for rel in "${required_jars[@]}"; do
            local full="${resolved_ghidra_path}/${rel}"
            if [[ ! -f "$full" ]]; then
                issues+=("Missing required Ghidra dependency: $full")
            fi
        done
    fi

    # Write access checks
    local install_ext_dir="${resolved_ghidra_path}/Extensions/Ghidra"
    if ! test_write_access "$install_ext_dir"; then
        issues+=("No write access to Ghidra extension directory: $install_ext_dir")
    else
        log_success "Write access OK: $install_ext_dir"
    fi

    # Optional strict network checks
    if [[ "$strict" == "true" ]]; then
        for url in "https://services.gradle.org" "https://repo.maven.apache.org" "https://pypi.org"; do
            if curl -sS --head --max-time 10 "$url" &>/dev/null; then
                log_success "Reachable: $url"
            else
                issues+=("Network check failed: $url")
            fi
        done
    fi

    if [[ ${#issues[@]} -gt 0 ]]; then
        log_error "Preflight checks failed:"
        for issue in "${issues[@]}"; do
            echo -e "  ${RED}-${NC} $issue"
        done
        return 1
    fi

    log_success "Preflight checks passed."
}

# ============================================================================
# Load .env file if present
# ============================================================================
env_file="${SCRIPT_DIR}/.env"
if [[ -f "$env_file" ]]; then
    while IFS='=' read -r key val; do
        # Skip comments and empty lines
        key=$(echo "$key" | sed 's/^[[:space:]]*//')
        [[ -z "$key" || "$key" =~ ^# ]] && continue
        val=$(echo "$val" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if [[ -n "$val" ]]; then
            export "$key=$val"
            verbose_log "Loaded from .env: $key"
        fi
    done < "$env_file"
fi

# ============================================================================
# Version resolution
# ============================================================================
pom_ghidra_version=$(get_pom_ghidra_version)

# If no --ghidra-version provided, try environment, then pom.xml, then default
if [[ -z "$GHIDRA_VERSION" ]]; then
    if [[ -n "${GHIDRA_VERSION_ENV:-}" ]]; then
        GHIDRA_VERSION="$GHIDRA_VERSION_ENV"
    elif [[ -n "$pom_ghidra_version" ]]; then
        GHIDRA_VERSION="$pom_ghidra_version"
    else
        GHIDRA_VERSION="$DEFAULT_GHIDRA_VERSION"
    fi
fi

# Version consistency check with pom.xml
if [[ -n "$pom_ghidra_version" && "$GHIDRA_VERSION" != "$pom_ghidra_version" ]]; then
    log_error "Version mismatch: selected GhidraVersion '${GHIDRA_VERSION}' does not match pom.xml ghidra.version '${pom_ghidra_version}'."
    log_info "Update pom.xml or pass matching --ghidra-version."
    exit 1
fi

# If --ghidra-path not provided, try .env, then auto-detect
if [[ -z "$GHIDRA_PATH" ]]; then
    GHIDRA_PATH="${GHIDRA_PATH:-}"
fi
if [[ -z "$GHIDRA_PATH" ]]; then
    # Auto-detect from common Linux installation paths
    common_paths=(
        "/opt/ghidra_${GHIDRA_VERSION}_PUBLIC"
        "$HOME/ghidra_${GHIDRA_VERSION}_PUBLIC"
        "/usr/local/ghidra_${GHIDRA_VERSION}_PUBLIC"
        "/usr/share/ghidra_${GHIDRA_VERSION}_PUBLIC"
        "$HOME/Tools/ghidra_${GHIDRA_VERSION}_PUBLIC"
        "$HOME/Downloads/ghidra_${GHIDRA_VERSION}_PUBLIC"
    )
    for path in "${common_paths[@]}"; do
        if [[ -f "${path}/ghidraRun" ]]; then
            GHIDRA_PATH="$path"
            log_info "Auto-detected Ghidra at: $GHIDRA_PATH"
            break
        fi
    done
fi

# Version consistency check with path
if [[ -n "$GHIDRA_PATH" ]]; then
    path_ghidra_version=$(get_version_from_ghidra_properties "$GHIDRA_PATH")
    if [[ -z "$path_ghidra_version" ]]; then
        path_ghidra_version=$(get_version_from_ghidra_path "$GHIDRA_PATH")
    fi
    if [[ -n "$path_ghidra_version" && "$path_ghidra_version" != "$GHIDRA_VERSION" ]]; then
        # Extract major.minor for compatibility check
        path_major_minor=$(echo "$path_ghidra_version" | cut -d. -f1-2)
        selected_major_minor=$(echo "$GHIDRA_VERSION" | cut -d. -f1-2)
        if [[ "$path_major_minor" == "$selected_major_minor" ]]; then
            log_warning "GhidraPath version '${path_ghidra_version}' differs from build version '${GHIDRA_VERSION}' (patch mismatch)."
            log_info "Extensions are generally compatible across patch versions. Continuing."
        else
            log_error "Version mismatch: GhidraPath implies version '${path_ghidra_version}', but selected/pom version is '${GHIDRA_VERSION}'."
            log_info "Use a matching --ghidra-path or update pom.xml ghidra.version."
            exit 1
        fi
    fi
fi

# Ghidra path is required for most actions
if [[ -z "$GHIDRA_PATH" && "$ACTION" != "build-only" && "$ACTION" != "clean" ]]; then
    log_error "Ghidra installation not found."
    log_info "Set GHIDRA_PATH in .env file, or pass --ghidra-path parameter:"
    echo "  ./ghidra-mcp-setup.sh --deploy --ghidra-path '/opt/ghidra_${GHIDRA_VERSION}_PUBLIC'"
    echo ""
    log_info "Or create a .env file from the template:"
    echo "  cp .env.template .env"
    echo "  # Edit .env and set GHIDRA_PATH"
    exit 1
fi

# Default action is deploy
if [[ -z "$ACTION" ]]; then
    ACTION="deploy"
fi

# ============================================================================
# Banner
# ============================================================================
echo ""
echo -e "${MAGENTA}======================================${NC}"
echo -e "${MAGENTA}  GhidraMCP Automation Script v2.0   ${NC}"
echo -e "${MAGENTA}  Target: Ghidra ${GHIDRA_VERSION} (Linux)   ${NC}"
echo -e "${MAGENTA}======================================${NC}"
echo ""

# ============================================================================
# Action: Clean
# ============================================================================
if [[ "$ACTION" == "clean" ]]; then
    invoke_clean_action
    exit 0
fi

# ============================================================================
# Action: Preflight
# ============================================================================
if [[ "$ACTION" == "preflight" ]]; then
    invoke_preflight_checks "$GHIDRA_PATH" "$GHIDRA_VERSION" "$STRICT_PREFLIGHT" && exit 0 || exit 1
fi

# ============================================================================
# Action: Build Only
# ============================================================================
if [[ "$ACTION" == "build-only" ]]; then
    if [[ -z "${GHIDRA_PATH:-}" ]]; then
        log_error "GHIDRA_PATH is required for build. Pass --ghidra-path or set GHIDRA_PATH."
        exit 1
    fi
    do_build || exit 1
    log_success "Build-only action completed."
    exit 0
fi

# ============================================================================
# Action: Setup Dependencies
# ============================================================================
if [[ "$ACTION" == "setup-deps" ]]; then
    if [[ ! -f "${GHIDRA_PATH}/ghidraRun" ]]; then
        log_error "Ghidra not found at: $GHIDRA_PATH"
        log_info "Please specify the correct path: ./ghidra-mcp-setup.sh --setup-deps --ghidra-path '/path/to/ghidra'"
        exit 1
    fi

    validate_ghidra_jars "$GHIDRA_PATH" || exit 1

    # Pick a build tool to decide whether m2 install is needed.
    select_build_tool || exit 1
    if [[ "$RESOLVED_BUILD_TOOL" == "mvn" ]]; then
        install_ghidra_dependencies "$GHIDRA_PATH" "$RESOLVED_BUILD_BIN" || exit 1
    else
        log_info "Gradle reads Ghidra JARs directly from GHIDRA_INSTALL_DIR — no m2 install needed."
    fi
    log_success "Setup-deps completed."
    exit 0
fi

# ============================================================================
# Action: Deploy (default)
# ============================================================================

# Validate Ghidra path
if [[ ! -f "${GHIDRA_PATH}/ghidraRun" ]]; then
    log_error "Ghidra not found at: $GHIDRA_PATH"
    log_info "Please specify the correct path: ./ghidra-mcp-setup.sh --ghidra-path '/path/to/ghidra'"
    exit 1
fi
log_success "Found Ghidra at: $GHIDRA_PATH"

# Preflight checks
if ! invoke_preflight_checks "$GHIDRA_PATH" "$GHIDRA_VERSION" "$STRICT_PREFLIGHT"; then
    exit 1
fi

# Auto prerequisites
if ! $NO_AUTO_PREREQS; then
    log_info "Auto-prerequisite mode enabled: ensuring dependencies before deploy..."
    install_python_packages || { log_error "Python package installation failed"; exit 1; }
    validate_ghidra_jars "$GHIDRA_PATH" || { log_error "Ghidra JAR validation failed"; exit 1; }

    # If we'll be building with Maven, ensure Ghidra JARs are in local m2.
    # do_build() also handles this, but doing it here surfaces the mvn-deps
    # cost before the longer compile step.
    if select_build_tool && [[ "$RESOLVED_BUILD_TOOL" == "mvn" ]]; then
        install_ghidra_dependencies "$GHIDRA_PATH" "$RESOLVED_BUILD_BIN" \
            || { log_error "Ghidra m2 dependency install failed"; exit 1; }
    fi
else
    log_info "Auto-prerequisite mode disabled (--no-auto-prereqs)."
fi

# Check if Ghidra is running BEFORE deployment
ghidra_was_running=false
if [[ -n "$(get_ghidra_pids)" ]]; then
    log_warning "Ghidra is currently running - files may be locked"
    if ! $SKIP_RESTART; then
        log_info "Closing Ghidra before deployment..."
        if close_ghidra; then
            ghidra_was_running=true
            log_success "Ghidra closed successfully"
        fi
    else
        log_warning "Ghidra is running but --skip-restart specified."
    fi
fi

# Clean up ALL cached GhidraMCP extensions
ghidra_config_base="$HOME/.config/ghidra"
if [[ -d "$ghidra_config_base" ]]; then
    cleaned_count=0
    for version_dir in "$ghidra_config_base"/ghidra_*; do
        if [[ -d "$version_dir" ]]; then
            ext_path="${version_dir}/Extensions/GhidraMCP"
            if [[ -d "$ext_path" ]]; then
                if ! $DRY_RUN; then
                    rm -rf "$ext_path" && cleaned_count=$((cleaned_count + 1))
                else
                    log_info "[DRY RUN] Would remove: $ext_path"
                fi
            fi
        fi
    done
    if [[ $cleaned_count -gt 0 ]]; then
        log_info "Cleaned ${cleaned_count} cached GhidraMCP extension(s)"
    fi
fi

# Build the extension (unless skipped)
if ! $SKIP_BUILD; then
    log_info "Building GhidraMCP extension..."
    if ! do_build; then
        log_error "Build failed"
        exit 1
    fi
    log_success "Build completed successfully"
else
    log_info "Skipping build (using existing artifact)"
fi

# Detect version from pom.xml
pom_path="${SCRIPT_DIR}/pom.xml"
if [[ -f "$pom_path" ]]; then
    version=$(grep -oP '<version>\K[^<]+' "$pom_path" | head -1 || echo "$PLUGIN_VERSION")
    log_success "Detected version: $version"
else
    log_warning "pom.xml not found, using default version: $PLUGIN_VERSION"
    version="$PLUGIN_VERSION"
fi

# Find latest build artifact — Maven outputs to target/, Gradle outputs to dist/
artifact_path=""
for candidate in \
    "${SCRIPT_DIR}/target/GhidraMCP-${version}.zip" \
    "${SCRIPT_DIR}/dist/GhidraMCP-${version}.zip" \
    "${SCRIPT_DIR}/target/GhidraMCP.zip"; do
    if [[ -f "$candidate" ]]; then artifact_path="$candidate"; break; fi
done

if [[ -z "$artifact_path" ]]; then
    # Fallback: newest zip across both output dirs
    artifact_path=$(ls -t "${SCRIPT_DIR}"/{target,dist}/GhidraMCP*.zip 2>/dev/null | head -1 || true)
    if [[ -n "$artifact_path" ]]; then
        log_info "Auto-detected latest artifact: $(basename "$artifact_path")"
    else
        log_error "No build artifacts found in target/ or dist/"
        log_info "Please run the build first: ./ghidra-mcp-setup.sh --build-only --ghidra-path \"\$GHIDRA_INSTALL_DIR\""
        exit 1
    fi
fi

log_success "Using artifact: $(basename "$artifact_path") ($version)"

# ============================================================================
# Deploy to Ghidra Extensions directory
# ============================================================================
ext_install_dir="${GHIDRA_PATH}/Extensions/Ghidra"

log_info "Installing extension to: ${ext_install_dir}/"

if [[ ! -d "$ext_install_dir" ]]; then
    if ! $DRY_RUN; then
        mkdir -p "$ext_install_dir"
        log_info "Created extensions directory: ${ext_install_dir}"
    else
        log_info "[DRY RUN] Would create: ${ext_install_dir}"
    fi
fi

if [[ -d "${ext_install_dir}/GhidraMCP" ]]; then
    if ! $DRY_RUN; then
        rm -rf "${ext_install_dir}/GhidraMCP"
        log_success "Removed existing GhidraMCP extension"
    else
        log_info "[DRY RUN] Would remove: ${ext_install_dir}/GhidraMCP"
    fi
fi

if ! $DRY_RUN; then
    unzip -q -o "$artifact_path" -d "$ext_install_dir"
    log_success "Installed: $(basename "$artifact_path") → ${ext_install_dir}/GhidraMCP/"
else
    log_info "[DRY RUN] Would extract: $(basename "$artifact_path") → ${ext_install_dir}/"
fi

# ============================================================================
# Copy Python MCP bridge to Ghidra root (optional convenience copy)
# ============================================================================
bridge_source="${SCRIPT_DIR}/bridge_mcp_ghidra.py"
requirements_source="${SCRIPT_DIR}/requirements.txt"

if [[ -f "$bridge_source" ]]; then
    bridge_dest="${GHIDRA_PATH}/bridge_mcp_ghidra.py"
    if ! $DRY_RUN; then
        if cp "$bridge_source" "$bridge_dest" 2>/dev/null; then
            log_success "Installed: bridge_mcp_ghidra.py → ${GHIDRA_PATH}/"
        else
            log_warning "Could not copy bridge to Ghidra directory (permission denied?)"
            log_info "You can manually copy: cp bridge_mcp_ghidra.py ${GHIDRA_PATH}/"
        fi

        if [[ -f "$requirements_source" ]]; then
            if cp "$requirements_source" "${GHIDRA_PATH}/requirements.txt" 2>/dev/null; then
                log_success "Installed: requirements.txt → ${GHIDRA_PATH}/"
            fi
        fi
    else
        log_info "[DRY RUN] Would copy bridge_mcp_ghidra.py → ${GHIDRA_PATH}/"
    fi
else
    log_warning "Python bridge not found: $bridge_source"
fi

# ============================================================================
# Summary
# ============================================================================
echo ""
log_success "GhidraMCP v${version} Successfully Deployed!"
echo ""
log_info "Installation Locations:"
echo "   Extension:    ${ext_install_dir}/GhidraMCP/"
if [[ -f "${GHIDRA_PATH}/bridge_mcp_ghidra.py" ]]; then
    echo "   Python Bridge: ${GHIDRA_PATH}/bridge_mcp_ghidra.py"
fi
echo ""
log_info "Next Steps:"
if $NO_AUTO_PREREQS; then
    echo "1. If needed (first time only), install Python dependencies:"
    if $USE_VENV; then
        echo "      python3 -m venv .venv && .venv/bin/pip install -r requirements.txt"
    else
        echo "      pip install -r requirements.txt"
    fi
else
    echo "1. Python dependencies were auto-checked/installed."
    if $USE_VENV; then
        echo "   Run the bridge with: .venv/bin/python bridge_mcp_ghidra.py"
    fi
fi
echo "2. Start Ghidra"
echo "3. If plugin isn't automatically enabled:"
echo "      - In CodeBrowser: File > Configure > Configure All Plugins > GhidraMCP"
echo "      - Check the checkbox to enable"
echo "      - Click OK and restart Ghidra"
echo "4. To configure the server port:"
echo "      - In CodeBrowser: Edit > Tool Options > GhidraMCP HTTP Server"
echo ""
log_info "Usage:"
echo "   Ghidra: Tools > GhidraMCP > Start MCP Server"
if $USE_VENV; then
    echo "   Python: .venv/bin/python bridge_mcp_ghidra.py (from project root)"
else
    echo "   Python: python3 bridge_mcp_ghidra.py (from project root or Ghidra directory)"
fi
echo ""
log_info "Default Server: http://127.0.0.1:8089/"
echo ""

# Show version-specific release notes
if [[ "$version" =~ ^2\. ]]; then
    log_info "New in v2.0.0 - Major Release:"
    echo "   + 133 total endpoints (was 132)"
    echo "   + Ghidra 12.0.3 support"
    echo "   + Malware analysis: IOC extraction, behavior detection, anti-analysis detection"
    echo "   + Function similarity analysis with CFG comparison"
    echo "   + Control flow complexity analysis (cyclomatic complexity)"
    echo "   + Enhanced call graph: cycle detection, path finding, SCC analysis"
    echo "   + API call chain threat pattern detection"
    echo ""
fi

# Verify installation
if [[ -d "${ext_install_dir}/GhidraMCP" ]]; then
    file_size=$(du -sh "${ext_install_dir}/GhidraMCP" 2>/dev/null | cut -f1)
    log_success "Installation verified: ${file_size}"

    if ! $SKIP_RESTART; then
        # Check if any Ghidra is still running
        remaining_pids=$(get_ghidra_pids)
        if [[ -n "$remaining_pids" ]]; then
            log_warning "Ghidra processes still detected, attempting to close..."
            close_ghidra
            sleep 2
        fi

        # Start Ghidra
        log_info "Starting Ghidra..."
        if ! $DRY_RUN; then
            nohup "${GHIDRA_PATH}/ghidraRun" &>/dev/null &
            ghidra_pid=$!
            sleep 3

            if kill -0 "$ghidra_pid" 2>/dev/null; then
                log_success "Ghidra started successfully! (PID: ${ghidra_pid})"
                log_success "The updated plugin (v${version}) is now available."
            else
                log_info "Ghidra launch initiated - it may take a moment to fully start."
            fi
        else
            log_info "[DRY RUN] Would start: ${GHIDRA_PATH}/ghidraRun"
        fi
    else
        if $ghidra_was_running; then
            log_warning "Ghidra was closed but --skip-restart specified. Start Ghidra manually."
        else
            log_info "Skipping Ghidra restart (use without --skip-restart to auto-restart)"
        fi
    fi
else
    log_error "Installation verification failed!"
    exit 1
fi

echo ""
log_success "Deployment completed successfully!"
echo ""
