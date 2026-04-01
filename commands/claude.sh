#!/usr/bin/env bash
# boxer claude — Launch Claude Code inside a container

cmd_claude() {
    local name=""
    local claude_args=()

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --resume)       claude_args+=(--resume); shift ;;
            --print)        claude_args+=(--print); shift ;;
            --prompt)       claude_args+=(-p "$2"); shift 2 ;;
            --model)        claude_args+=(--model "$2"); shift 2 ;;
            -h|--help)
                cat <<'HELP'
Usage: boxer claude <name> [options]

Start a boxer container (if stopped), sync credentials and config
from the host, then launch Claude Code.

Arguments:
    <name>              Name of the boxer container

Options:
    --resume            Resume the last Claude session
    --print             Run in non-interactive print mode
    --prompt <text>     Pass an initial prompt to Claude
    --model <model>     Override the Claude model
HELP
                return 0
                ;;
            -*)
                die "Unknown option: $1"
                ;;
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
        die "Usage: boxer claude <name>"
    fi

    # Shared boot: start container, wait for readiness, sync creds+config
    source "$BOXER_ROOT/commands/start.sh"
    _boxer_boot "$name"

    # Pre-session: freshen the container's active profile (captures any
    # prior rotation that was never saved)
    docker exec --user "$BOXER_CONTAINER_USER" "$name" \
        bash -c 'command -v cs >/dev/null 2>&1 && cs freshen --quiet' 2>/dev/null || true

    # Launch Claude Code CLI
    log_info "Launching Claude Code in '$name'..."
    local exec_cmd=(docker exec -it --user "$BOXER_CONTAINER_USER" "$name")
    exec_cmd+=(claude --dangerously-skip-permissions)
    exec_cmd+=("${claude_args[@]}")

    MSYS_NO_PATHCONV=1 "${exec_cmd[@]}" || true

    # Post-session: capture any token rotation from the Claude session
    log_info "Capturing credential state..."
    docker exec --user "$BOXER_CONTAINER_USER" "$name" \
        bash -c 'command -v cs >/dev/null 2>&1 && cs freshen --quiet' 2>/dev/null || true

    # Pull freshened profile back to host
    source "$BOXER_ROOT/commands/credential.sh"
    _pull_container_profiles "$name" 2>/dev/null || true

    log_info "Claude session ended. Container '$name' is still running."
    log_info "  Re-enter:  boxer claude $name"
    log_info "  Shell:     boxer start $name"
    log_info "  Stop:      boxer stop $name"
}
