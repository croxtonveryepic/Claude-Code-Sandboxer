#!/usr/bin/env bash
# boxer start — Start a container and open a shell

cmd_start() {
    local name=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                cat <<'HELP'
Usage: boxer start <name>

Start a boxer container (if stopped), sync profiles and config
from the host, then open an interactive bash shell.

To launch Claude Code directly, use: boxer claude <name>
HELP
                return 0
                ;;
            -*)  die "Unknown option: $1" ;;
            *)
                if [[ -z "$name" ]]; then
                    name="$1"
                else
                    die "Unexpected argument: $1"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$name" ]]; then
        die "Usage: boxer start <name>"
    fi

    _boxer_boot "$name"

    log_info "Opening shell in '$name'..."
    docker exec -it --user "$BOXER_CONTAINER_USER" "$name" bash

    log_info "Shell exited. Container '$name' is still running."
    log_info "  Re-enter:  boxer start $name"
    log_info "  Claude:    boxer claude $name"
    log_info "  Stop:      boxer stop $name"
}

# ── Shared boot sequence (used by start and claude commands) ──

# Start the container, wait for readiness, sync profiles and config.
_boxer_boot() {
    local name="$1"

    require_docker
    require_boxer_container "$name"

    # Start the container if not running
    local status
    status="$(container_status "$name")"
    if [[ "$status" != "running" ]]; then
        log_info "Starting container '$name'..."
        docker start "$name" >/dev/null
        # Wait for entrypoint to finish firewall setup
        log_info "Waiting for container to be ready..."
        local waited=0
        while ! docker exec "$name" test -f /tmp/.boxer-ready 2>/dev/null; do
            sleep 0.2
            waited=$((waited + 1))
            if [[ $waited -ge 50 ]]; then
                log_warn "Container readiness timed out after 10s, proceeding anyway"
                break
            fi
        done
    fi

    # Ensure ~/.claude directory exists for config sync
    docker exec "$name" mkdir -p "${BOXER_CONTAINER_HOME}/.claude" 2>/dev/null || true

    # Copy Claude Code customization (rules, settings, agents, profiles, etc.)
    _sync_claude_config "$name"
}

# Sync Claude Code customization from host ~/.claude into the container
_sync_claude_config() {
    local name="$1"
    local src_dir="$HOME/.claude"
    local dest_dir="${BOXER_CONTAINER_HOME}/.claude"

    local sync_enabled
    sync_enabled="$(boxer_config sync claude_config "true")"
    if [[ "$sync_enabled" != "true" ]]; then
        return
    fi

    if [[ ! -d "$src_dir" ]]; then
        return
    fi

    log_info "Syncing Claude Code config into container..."

    # Individual files to sync
    local files=(
        CLAUDE.md
        settings.json
        settings.local.json
        keybindings.json
    )

    for f in "${files[@]}"; do
        if [[ -f "$src_dir/$f" ]]; then
            MSYS_NO_PATHCONV=1 docker cp "$src_dir/$f" "${name}:${dest_dir}/$f"
        fi
    done

    # Directories to sync (entire trees)
    local dirs=(
        rules
        agents
        commands
        skills
        hooks
        ecc
        plugins
        profiles
    )

    for d in "${dirs[@]}"; do
        if [[ -d "$src_dir/$d" ]]; then
            # Remove stale copy, then copy fresh
            docker exec "$name" rm -rf "$dest_dir/$d" 2>/dev/null || true
            MSYS_NO_PATHCONV=1 docker cp "$src_dir/$d" "${name}:${dest_dir}/$d"
        fi
    done

    # Remove host's .active marker — each container tracks its own active profile
    docker exec "$name" rm -f "$dest_dir/profiles/.active" 2>/dev/null || true

    # Fix ownership for everything we just copied
    docker exec "$name" chown -R "${BOXER_CONTAINER_USER}:${BOXER_CONTAINER_USER}" "$dest_dir" 2>/dev/null || true

    # Restrict profile file permissions (contain OAuth refresh tokens)
    docker exec "$name" find "$dest_dir/profiles" -name '*.json' -exec chmod 600 {} + 2>/dev/null || true
}
