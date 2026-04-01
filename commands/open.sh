#!/usr/bin/env bash
# boxer open — Open the firewall on a container (allow all outbound)

cmd_open() {
    local name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                cat <<'HELP'
Usage: boxer open <name>

Open the outbound firewall on a running container, allowing
unrestricted internet access. Use 'boxer close <name>' to
restore the restricted allowlist.
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
        die "Usage: boxer open <name>"
    fi

    require_docker
    require_boxer_container "$name"

    local status
    status="$(container_status "$name")"
    if [[ "$status" != "running" ]]; then
        die "Container '$name' is not running (status: $status). Start it first with 'boxer start $name'."
    fi

    log_info "Opening firewall on '$name'..."

    docker exec --user root "$name" bash -c 'iptables -F OUTPUT 2>/dev/null || true && iptables -P OUTPUT ACCEPT'

    log_success "Firewall opened on '$name' — all outbound traffic allowed."
    log_warn "Run 'boxer close $name' to restore the restricted allowlist."
}
