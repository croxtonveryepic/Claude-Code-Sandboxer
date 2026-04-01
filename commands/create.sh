#!/usr/bin/env bash
# boxer create — Create a new sandbox container

cmd_create() {
    local repo_path=""
    local name=""
    local cpu=""
    local memory=""
    local network=""
    local mount_ssh=""
    local mount_gitconfig=""
    local extra_envs=()
    local extra_domains=""
    local start_after=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cpu)          cpu="$2"; shift 2 ;;
            --memory)       memory="$2"; shift 2 ;;
            --network)      network="$2"; shift 2 ;;
            --no-ssh)       mount_ssh=false; shift ;;
            --no-git-config) mount_gitconfig=false; shift ;;
            --env)          extra_envs+=("$2"); shift 2 ;;
            --domains)      extra_domains="$2"; shift 2 ;;
            --start)        start_after=true; shift ;;
            -h|--help)
                cat <<'HELP'
Usage: boxer create <repo-path> <name> [options]

Arguments:
    <repo-path>     Path to the git repository to mount
    <name>          Unique name for the container

Options:
    --cpu <n>           CPU cores (default: 4)
    --memory <size>     Memory limit (default: 8g)
    --network <mode>    restricted, none, or host (default: restricted)
    --no-ssh            Don't mount SSH keys
    --no-git-config     Don't mount .gitconfig
    --env <KEY=VALUE>   Extra environment variable (repeatable)
    --domains <list>    Comma-separated extra firewall domains
    --start             Open a shell immediately after creation
HELP
                return 0
                ;;
            -*)
                die "Unknown option: $1. Run 'boxer create --help' for usage."
                ;;
            *)
                if [[ -z "$repo_path" ]]; then
                    repo_path="$1"
                elif [[ -z "$name" ]]; then
                    name="$1"
                else
                    die "Unexpected argument: $1"
                fi
                shift
                ;;
        esac
    done

    # Validate required args
    if [[ -z "$repo_path" ]] || [[ -z "$name" ]]; then
        die "Usage: boxer create <repo-path> <name> [options]"
    fi

    # Apply config defaults
    cpu="${cpu:-$(boxer_config defaults cpu "$BOXER_DEFAULT_CPU")}"
    memory="${memory:-$(boxer_config defaults memory "$BOXER_DEFAULT_MEMORY")}"
    network="${network:-$(boxer_config defaults network "$BOXER_DEFAULT_NETWORK")}"
    [[ -z "$mount_ssh" ]] && mount_ssh="$(boxer_config mounts ssh "true")"
    [[ -z "$mount_gitconfig" ]] && mount_gitconfig="$(boxer_config mounts gitconfig "true")"

    if [[ -z "$extra_domains" ]]; then
        extra_domains="$(boxer_config firewall extra_domains "")"
    fi

    require_docker
    validate_name "$name"

    if container_exists "$name"; then
        die "Container '$name' already exists. Choose a different name or run 'boxer rm $name' first."
    fi

    # Resolve repo path for Docker
    if [[ ! -d "$repo_path" ]]; then
        die "Repository path does not exist: $repo_path"
    fi
    local docker_repo_path
    docker_repo_path="$(resolve_path "$repo_path")"

    # Workspace mount point inside the container, named after the repo
    local repo_basename
    repo_basename="$(basename "$repo_path")"
    local workspace="${BOXER_CONTAINER_HOME}/${repo_basename}"

    # Ensure the boxer image is built
    ensure_image

    log_info "Creating container '$name'..."
    log_info "  Repo: $docker_repo_path"
    log_info "  CPU: $cpu | Memory: $memory | Network: $network"

    # Build docker create command
    local cmd=(docker create)
    cmd+=(--name "$name")

    # Labels
    cmd+=(--label "boxer.managed=true")
    cmd+=(--label "boxer.repo.path=$docker_repo_path")
    cmd+=(--label "boxer.created.at=$(date -u +%Y-%m-%dT%H:%M:%SZ)")
    cmd+=(--label "boxer.version=$BOXER_VERSION")
    cmd+=(--label "boxer.network=$network")
    cmd+=(--label "boxer.workspace=$workspace")

    # Resource limits
    cmd+=(--cpus "$cpu")
    cmd+=(--memory "$memory")

    # Security
    cmd+=(--cap-add NET_ADMIN)
    cmd+=(--security-opt "no-new-privileges")

    # Repo mount (read-write for Claude to edit code)
    cmd+=(-v "$docker_repo_path:$workspace")

    # Claude config persistence via named volumes
    cmd+=(-v "${BOXER_VOLUME_PREFIX}-${name}-claude-config:${BOXER_CONTAINER_HOME}/.claude")
    cmd+=(-v "${BOXER_VOLUME_PREFIX}-${name}-claude-data:${BOXER_CONTAINER_HOME}/.local/share/claude")

    # SSH keys (read-only)
    if [[ "$mount_ssh" == "true" ]]; then
        local ssh_path
        ssh_path="$(to_docker_path "$HOME/.ssh")"
        if [[ -d "$HOME/.ssh" ]]; then
            cmd+=(-v "$ssh_path:/root/.ssh-staging:ro")
        else
            log_warn "~/.ssh not found, skipping SSH mount"
        fi
    fi

    # Git config (read-only)
    if [[ "$mount_gitconfig" == "true" ]]; then
        local gitconfig_path
        gitconfig_path="$(to_docker_path "$HOME/.gitconfig")"
        if [[ -f "$HOME/.gitconfig" ]]; then
            cmd+=(-v "$gitconfig_path:${BOXER_CONTAINER_HOME}/.gitconfig:ro")
        else
            log_warn "~/.gitconfig not found, skipping git config mount"
        fi
    fi

    # Environment: override Windows-specific git settings for Linux container
    cmd+=(-e "GIT_SSH_COMMAND=ssh")
    cmd+=(-e "GIT_CONFIG_COUNT=1")
    cmd+=(-e "GIT_CONFIG_KEY_0=core.autocrlf")
    cmd+=(-e "GIT_CONFIG_VALUE_0=input")
    cmd+=(-e "BOXER_CONTAINER=true")
    cmd+=(-e "BOXER_CONTAINER_NAME=$name")
    cmd+=(-e "BOXER_REPO_NAME=$repo_basename")
    cmd+=(-e "BOXER_WORKSPACE=$workspace")

    # Extra firewall domains
    if [[ -n "$extra_domains" ]]; then
        cmd+=(-e "BOXER_EXTRA_DOMAINS=$extra_domains")
    fi

    # Network mode
    case "$network" in
        restricted) ;; # Default bridge network, firewall handles restriction
        none)       cmd+=(--network none) ;;
        host)       cmd+=(--network host) ;;
        *)          die "Invalid network mode: $network. Use: restricted, none, host" ;;
    esac

    # Extra user-provided environment variables
    if [[ ${#extra_envs[@]} -gt 0 ]]; then
        for env_var in "${extra_envs[@]}"; do
            cmd+=(-e "$env_var")
        done
    fi

    # Interactive/TTY support
    cmd+=(-it)

    # Image
    cmd+=("$BOXER_IMAGE")

    # Execute
    MSYS_NO_PATHCONV=1 "${cmd[@]}" >/dev/null
    log_success "Container '$name' created."

    if $start_after; then
        source "$BOXER_ROOT/commands/start.sh"
        cmd_start "$name"
    fi
}
