#!/usr/bin/env bash
# boxer credential — Manage Claude credentials and switcher across containers

# Resolve the claude-switch.py script on the host
_resolve_claude_switch_script() {
    local script="$BOXER_ROOT/claude-switch.py"
    if [[ -f "$script" ]]; then
        echo "$script"
    else
        echo ""
    fi
}

cmd_credential() {
    local subcmd="${1:-}"
    shift || true

    case "$subcmd" in
        sync)    cmd_credential_sync "$@" ;;
        pull)    cmd_credential_pull "$@" ;;
        freshen) cmd_credential_freshen "$@" ;;
        install) cmd_credential_install "$@" ;;
        -h|--help|help|"")
            cat <<'HELP'
Usage: boxer credential <subcommand>

Subcommands:
    sync [<name>]           Pull-merge-push: freshen host profile, pull
                            freshened profiles from containers, merge by
                            timestamp, then push to containers. If <name>
                            is given, only sync that container.
    pull                    Pull freshened profiles from running containers
                            and merge into host profiles by timestamp
    freshen                 Freshen the host's active profile from live
                            credentials (captures token rotation)
    install <name>          Install/update Claude Switcher on a specific
                            running container

The sync command performs a full bidirectional reconciliation:
  1. Freshens the host's active profile from live credentials
  2. Pulls freshened profiles from running containers
  3. Merges by token_updated_at timestamp (newest wins)
  4. Pushes merged profiles and config to containers
HELP
            ;;
        *) die "Unknown subcommand: $subcmd. Run 'boxer credential --help' for usage." ;;
    esac
}

# ── Freshen (host-side) ─────────────────────────────────────────────

cmd_credential_freshen() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) cmd_credential "help"; return 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    local cs_script
    cs_script="$(_resolve_claude_switch_script)"
    if [[ -z "$cs_script" ]]; then
        die "claude-switch.py not found at $BOXER_ROOT/claude-switch.py"
    fi

    local py
    py="$(resolve_host_python)" || die "Python not found. Install Python 3 and ensure 'python' is on PATH."

    log_info "Freshening host active profile..."
    "$py" "$cs_script" freshen
}

# ── Pull from containers ────────────────────────────────────────────

# Read token_updated_at from a profile JSON file, normalising Z -> +00:00.
# Returns the timestamp string, or the epoch fallback on error.
_read_profile_timestamp() {
    local file="$1"
    local py
    py="$(resolve_host_python)" || { echo "1970-01-01T00:00:00+00:00"; return; }
    "$py" -c "
import json, sys
d = json.load(open(sys.argv[1], 'r'))
ts = d.get('token_updated_at', '1970-01-01T00:00:00+00:00')
if ts.endswith('Z'):
    ts = ts[:-1] + '+00:00'
print(ts)
" "$file" 2>/dev/null || echo "1970-01-01T00:00:00+00:00"
}

# Pull freshened profiles from a single running container and merge
# into host profiles by timestamp. Returns 0 on success.
_pull_container_profiles() {
    local name="$1"
    local dest_dir="$HOME/.claude/profiles"
    local container_profiles_dir="${BOXER_CONTAINER_HOME}/.claude/profiles"

    # Freshen the container's active profile first
    docker exec --user "$BOXER_CONTAINER_USER" "$name" \
        bash -c 'command -v cs >/dev/null 2>&1 && cs freshen --quiet' 2>/dev/null || true

    # Create temp dir for pulling
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap "rm -rf '$tmp_dir'" RETURN

    # Copy container profiles to temp dir
    MSYS_NO_PATHCONV=1 docker cp "${name}:${container_profiles_dir}/." "$tmp_dir/" 2>/dev/null || {
        log_info "  $name: no profiles to pull"
        return 0
    }

    # Merge each profile by timestamp
    local updated=0
    for container_file in "$tmp_dir"/*.json; do
        [[ -f "$container_file" ]] || continue
        local basename
        basename="$(basename "$container_file")"
        local host_file="$dest_dir/$basename"

        local container_ts
        container_ts="$(_read_profile_timestamp "$container_file")" || continue

        if [[ ! -f "$host_file" ]]; then
            # New profile from container — adopt it
            cp "$container_file" "$host_file"
            updated=$((updated + 1))
            log_info "  $name: new profile '${basename%.json}' pulled"
            continue
        fi

        local host_ts
        host_ts="$(_read_profile_timestamp "$host_file")" || continue

        # INVARIANT: Both timestamps are produced by claude-switch.py's now_iso(),
        # which always outputs UTC with +00:00 offset. _read_profile_timestamp
        # normalises any trailing "Z" to "+00:00", so lexicographic string
        # comparison is equivalent to chronological ordering.
        if [[ "$container_ts" > "$host_ts" ]]; then
            cp "$container_file" "$host_file"
            updated=$((updated + 1))
            log_info "  $name: profile '${basename%.json}' updated (container token is newer)"
        fi
    done

    if [[ $updated -eq 0 ]]; then
        log_info "  $name: all profiles current"
    fi
    return 0
}

cmd_credential_pull() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) cmd_credential "help"; return 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    require_docker

    local containers
    containers="$(list_boxer_containers)"

    if [[ -z "$containers" ]]; then
        log_info "No boxer containers found."
        return 0
    fi

    # Ensure host profiles dir exists
    mkdir -p "$HOME/.claude/profiles"

    local total=0
    local pulled=0
    local skipped=0

    while IFS= read -r name; do
        total=$((total + 1))
        local status
        status="$(container_status "$name")"

        if [[ "$status" != "running" ]]; then
            log_info "  $name: skipped (${status})"
            skipped=$((skipped + 1))
            continue
        fi

        # Check if cs is installed
        if ! docker exec "$name" test -f /usr/local/bin/cs 2>/dev/null; then
            log_info "  $name: skipped (Claude Switcher not installed)"
            skipped=$((skipped + 1))
            continue
        fi

        _pull_container_profiles "$name" || {
            log_warn "  $name: pull failed (non-fatal)"
        }
        pulled=$((pulled + 1))
    done <<< "$containers"

    log_success "Pull complete: $pulled pulled, $skipped skipped (of $total total)"
}

# ── Sync (pull-then-push) ───────────────────────────────────────────

cmd_credential_sync() {
    local target_name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) cmd_credential "help"; return 0 ;;
            -*)  die "Unknown option: $1" ;;
            *)
                if [[ -z "$target_name" ]]; then
                    target_name="$1"
                else
                    die "Unexpected argument: $1"
                fi
                shift
                ;;
        esac
    done

    require_docker

    # Validate target container if specified
    if [[ -n "$target_name" ]]; then
        require_boxer_container "$target_name"
        local target_status
        target_status="$(container_status "$target_name")"
        if [[ "$target_status" != "running" ]]; then
            die "Container '$target_name' is not running (status: $target_status). Start it first with: boxer start $target_name"
        fi
    fi

    # Phase 1: Freshen host active profile
    local cs_script
    cs_script="$(_resolve_claude_switch_script)"
    local py
    py="$(resolve_host_python)" || true
    if [[ -n "$cs_script" && -n "$py" ]]; then
        log_info "Freshening host active profile..."
        "$py" "$cs_script" freshen --quiet 2>/dev/null || true
    fi

    local containers
    if [[ -n "$target_name" ]]; then
        containers="$target_name"
    else
        containers="$(list_boxer_containers)"
    fi

    if [[ -z "$containers" ]]; then
        log_info "No boxer containers found."
        return 0
    fi

    # Phase 2: Pull from running containers
    log_info "Pulling profiles from containers..."
    mkdir -p "$HOME/.claude/profiles"

    while IFS= read -r name; do
        local status
        status="$(container_status "$name")"
        if [[ "$status" == "running" ]]; then
            if docker exec "$name" test -f /usr/local/bin/cs 2>/dev/null; then
                _pull_container_profiles "$name" 2>/dev/null || true
            fi
        fi
    done <<< "$containers"

    # Depends on start.sh for _sync_claude_config
    # (sourced by the dispatcher in boxer before this file)

    # Phase 3: Push to containers
    log_info "Pushing profiles to containers..."

    local total=0
    local synced=0
    local skipped=0

    while IFS= read -r name; do
        total=$((total + 1))
        local status
        status="$(container_status "$name")"

        if [[ "$status" != "running" ]]; then
            log_info "  $name: skipped (${status}, will sync on next start)"
            skipped=$((skipped + 1))
            continue
        fi

        log_info "  $name: pushing..."

        # Ensure ~/.claude directory exists
        docker exec "$name" mkdir -p "${BOXER_CONTAINER_HOME}/.claude" 2>/dev/null || true

        # Sync profiles and Claude Code config
        _sync_claude_config "$name" 2>/dev/null || true

        # Harden permissions on credential and profile files
        _harden_credential_permissions "$name"

        # Auto-install/update Claude Switcher
        if [[ -n "$cs_script" ]]; then
            _install_claude_switcher "$name" "$cs_script" 2>/dev/null || {
                log_warn "  $name: Claude Switcher install failed (non-fatal)"
            }
        fi

        synced=$((synced + 1))
    done <<< "$containers"

    log_success "Credential sync complete: $synced synced, $skipped skipped (of $total total)"
}

# ── Install ──────────────────────────────────────────────────────────

cmd_credential_install() {
    local name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) cmd_credential "help"; return 0 ;;
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
        die "Usage: boxer credential install <name>"
    fi

    require_docker
    require_boxer_container "$name"

    local status
    status="$(container_status "$name")"
    if [[ "$status" != "running" ]]; then
        die "Container '$name' is not running (status: $status). Start it first with: boxer start $name"
    fi

    local cs_script
    cs_script="$(_resolve_claude_switch_script)"
    if [[ -z "$cs_script" ]]; then
        die "claude-switch.py not found at $BOXER_ROOT/claude-switch.py"
    fi

    _install_claude_switcher "$name" "$cs_script"
    log_success "Claude Switcher installed in '$name'. Use 'cs status' inside the container."
}

# Install or update claude-switch.py and the cs wrapper in a running container
_install_claude_switcher() {
    local name="$1"
    local script_path="$2"

    MSYS_NO_PATHCONV=1 docker cp "$script_path" "${name}:/usr/local/bin/claude-switch.py"

    docker exec "$name" bash -c '
        printf "#!/bin/sh\nexec python3 /usr/local/bin/claude-switch.py \"\$@\"\n" > /usr/local/bin/cs
        chmod +x /usr/local/bin/claude-switch.py /usr/local/bin/cs
    '

    docker exec "$name" chown "${BOXER_CONTAINER_USER}:${BOXER_CONTAINER_USER}" \
        /usr/local/bin/claude-switch.py /usr/local/bin/cs 2>/dev/null || true
}

# Set restrictive permissions on profile files
_harden_credential_permissions() {
    local name="$1"
    local dest_dir="${BOXER_CONTAINER_HOME}/.claude"

    docker exec "$name" bash -c "
        if [ -d '$dest_dir/profiles' ]; then
            find '$dest_dir/profiles' -name '*.json' -exec chmod 600 {} + 2>/dev/null || true
        fi
    "
}
