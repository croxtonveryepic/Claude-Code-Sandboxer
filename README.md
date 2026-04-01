# Boxer

Quickly spin up isolated Docker containers for running Claude Code CLI with `--dangerously-skip-permissions`.

## Prerequisites

- **Docker Desktop** (running)
- **PowerShell 7+** (`pwsh`)

## Installation

```powershell
.\Install.ps1
```

This installs the `boxer` command to your PowerShell profile and `~/bin`. Restart your terminal or run `. $PROFILE` to load it.

## Quick Start

```powershell
boxer create /repo/path project-name
boxer start project-name                             #      it's that easy!
/workspace$ claude --dangerously-skip-permissions    # <--- this is safe! (probably!)
```

## Credential Management

Sandboxer ships with `claude-switch.py` (aliased as `cs`), a credential manager that saves, switches, and auto-synchronizes Claude Code OAuth tokens across the host and containers. Claude Code automatically rotates its OAuth refresh token; `cs` detects these rotations and propagates the updated token back into the correct profile, regardless of which environment (host or container) performed the rotation.

### Setup

```powershell
# 1. On the host: save your current Claude Code session as a named profile
cs save work

# 2. Push profiles and install cs into all running containers
boxer credential sync

# 3. Inside a container: activate a profile
cs use work
```

You can save multiple profiles if you have separate Anthropic accounts (e.g. `work` and `personal`).

### Token Rotation Lifecycle

Token freshening happens automatically at several points:

1. **Pre-session** (`boxer claude <name>`): Before launching Claude Code, `cs freshen` runs in the container to capture any rotation from a prior session.
2. **Post-session** (`boxer claude <name>`): After the Claude session exits, `cs freshen` runs again to capture any rotation that occurred during the session, then the freshened profile is pulled back to the host.
3. **Shell login**: Each time you open a shell in a container, a background `cs freshen` runs (serialized with `flock` to avoid races).
4. **Credential sync** (`boxer credential sync`): Performs a full bidirectional reconciliation — freshens the host profile, pulls from all containers, merges by timestamp (newest wins), then pushes to all containers.

### `cs` Commands (inside containers or on the host)

| Command | Description |
| --- | --- |
| `cs save <name>` | Capture the current Claude Code session as a named profile |
| `cs save <name> --overwrite` | Overwrite an existing profile |
| `cs use <name>` | Switch to a named profile (auto-freshens the outgoing profile) |
| `cs status` | Show all profiles with active indicator and staleness detection |
| `cs freshen` | Update the active profile from live credentials |
| `cs freshen --force` | Reconstruct `.active` from the live token if missing/corrupt, then freshen |
| `cs freshen --all` | Migrate all profiles to v2 schema, synthesize `.active` if missing, then freshen |

### `boxer credential` Subcommands

| Command | Description |
| --- | --- |
| `boxer credential sync` | Full bidirectional sync (freshen, pull, merge by timestamp, push) |
| `boxer credential pull` | Pull freshened profiles from all running containers to the host |
| `boxer credential freshen` | Freshen the host's active profile from live credentials |
| `boxer credential install <name>` | Install/update Claude Switcher in a specific container |

### Recovery

If the `.active` marker file is lost or corrupted:

- **`cs freshen --force`** — reconstructs `.active` by matching the live token against saved profiles, then freshens.
- **`cs freshen --all`** — same recovery, plus migrates any v1 profiles to v2 schema.
- **`cs save <name> --overwrite`** — last resort: re-captures the current session from scratch.

## Commands

| Command                      | Description                                                            |
| ---------------------------- | ---------------------------------------------------------------------- |
| `boxer create <repo> <name>` | Create a new sandbox container                                         |
| `boxer start <name>`         | Start a Claude Code session                                            |
| `boxer stop <name>`          | Stop a container (`--all` for all)                                     |
| `boxer rm <name>`            | Remove a container (`--volumes` to delete data)                        |
| `boxer list`                 | List all boxer containers                                              |
| `boxer status <name>`        | Show container details and resource usage                              |
| `boxer logs <name>`          | Show container logs (`--follow`, `--tail`)                             |
| `boxer build`                | Build/rebuild the sandbox Docker image (auto-builds on first `create`) |

### Create Options

```
--cpu <n>           CPU cores (default: 4)
--memory <size>     Memory limit (default: 8g)
--network <mode>    restricted, none, or host (default: restricted)
--no-ssh            Don't mount SSH keys
--no-git-config     Don't mount .gitconfig
--env <KEY=VALUE>   Extra environment variable (repeatable)
--domains <list>    Comma-separated extra firewall domains
--start             Start a Claude session immediately after creation
```

## Configuration

Boxer creates a config file at `~/.boxer/config` on first run:

```ini
[defaults]
cpu = 4
memory = 8g
network = restricted

[firewall]
# Comma-separated extra domains to allow through the firewall
extra_domains =

[mounts]
ssh = true
gitconfig = true
```

CLI flags override config file values.

## Network Restrictions

In `restricted` mode (default), outbound traffic is limited to:

- **Anthropic** — api.anthropic.com, console.anthropic.com, claude.ai, statsig.anthropic.com
- **GitHub** — github.com (HTTPS + SSH), api.github.com
- **Package registries** — registry.npmjs.org, pypi.org, files.pythonhosted.org
- **DNS** — container's configured resolvers only
- **Custom domains** — via `--domains` flag or `extra_domains` config

All other outbound connections are dropped by iptables firewall rules.
