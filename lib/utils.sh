#!/usr/bin/env bash
# Boxer shared utilities: logging, path conversion, validation

# --- Logging ---

_color_reset="\033[0m"
_color_red="\033[0;31m"
_color_yellow="\033[0;33m"
_color_green="\033[0;32m"
_color_blue="\033[0;34m"

log_info() {
    printf "${_color_blue}[boxer]${_color_reset} %s\n" "$*"
}

log_success() {
    printf "${_color_green}[boxer]${_color_reset} %s\n" "$*"
}

log_warn() {
    printf "${_color_yellow}[boxer]${_color_reset} %s\n" "$*" >&2
}

log_error() {
    printf "${_color_red}[boxer]${_color_reset} %s\n" "$*" >&2
}

die() {
    log_error "$@"
    exit 1
}

# --- Path Conversion ---

# Convert a path to Docker-compatible format (Windows path for Docker Desktop)
to_docker_path() {
    local path="$1"

    # Already a Windows-style path (C:/ or C:\)
    if [[ "$path" =~ ^[A-Za-z]:[/\\] ]]; then
        echo "$path"
        return
    fi

    # Use cygpath if available (Git Bash provides this)
    if command -v cygpath &>/dev/null; then
        cygpath -w "$path"
        return
    fi

    # Manual conversion: /c/Users/... -> C:/Users/...
    if [[ "$path" =~ ^/([a-zA-Z])/(.*) ]]; then
        echo "${BASH_REMATCH[1]^^}:/${BASH_REMATCH[2]}"
        return
    fi

    # Fallback: return as-is
    echo "$path"
}

# Resolve to absolute path then convert for Docker
resolve_path() {
    local path="$1"
    local resolved

    # Resolve to absolute POSIX path
    resolved="$(cd "$path" 2>/dev/null && pwd)" || {
        die "Path does not exist: $path"
    }

    to_docker_path "$resolved"
}

# --- Validation ---

# Check Docker daemon is running
require_docker() {
    if ! docker info &>/dev/null; then
        die "Docker is not running. Start Docker Desktop and try again."
    fi
}

# Validate container name: alphanumeric, hyphens, underscores, 1-64 chars
validate_name() {
    local name="$1"

    if [[ -z "$name" ]]; then
        die "Container name is required."
    fi

    if [[ ! "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$ ]]; then
        die "Invalid container name '$name'. Use alphanumeric characters, hyphens, and underscores (1-64 chars, must start with alphanumeric)."
    fi
}

# Check if a container exists and is managed by boxer
is_boxer_container() {
    local name="$1"
    local label
    label="$(docker inspect --format '{{index .Config.Labels "boxer.managed"}}' "$name" 2>/dev/null)" || return 1
    [[ "$label" == "true" ]]
}

# Check if a container name is already in use
container_exists() {
    local name="$1"
    docker inspect "$name" &>/dev/null
}

# Require that a boxer container exists
require_boxer_container() {
    local name="$1"

    if ! container_exists "$name"; then
        die "Container '$name' does not exist. Run 'boxer list' to see available containers."
    fi

    if ! is_boxer_container "$name"; then
        die "Container '$name' exists but is not managed by boxer."
    fi
}

# Get container status (running, exited, created, etc.)
container_status() {
    local name="$1"
    docker inspect --format '{{.State.Status}}' "$name" 2>/dev/null
}

# --- Python Resolution ---

# Return a working host-side Python 3 command, skipping the
# Windows Store stub (WindowsApps/python3).
resolve_host_python() {
    local cmd path
    for cmd in python3 python; do
        if command -v "$cmd" >/dev/null 2>&1; then
            path="$(command -v "$cmd")"
            if [[ "$path" != *"WindowsApps"* ]]; then
                echo "$cmd"
                return 0
            fi
        fi
    done
    return 1
}
