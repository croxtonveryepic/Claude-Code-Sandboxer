# boxer start - Start a container and open a shell

function Invoke-BoxerStart {
    param(
        [Parameter(Position = 0)]
        [string]$Name,

        [switch]$Help
    )

    if ($Help) {
        Write-Host @"
Usage: boxer start <name>

Start a boxer container (if stopped), sync profiles and config
from the host, then open an interactive bash shell.

To launch Claude Code directly, use: boxer claude <name>
"@
        return
    }

    if ([string]::IsNullOrWhiteSpace($Name)) {
        Stop-BoxerWithError "Usage: boxer start <name>"
    }

    Initialize-BoxerContainer $Name

    $workspace = Get-ContainerLabel -Name $Name -Label "boxer.workspace"

    Write-BoxerInfo "Opening shell in '$Name'..."
    docker exec -it -w $workspace --user $script:BOXER_CONTAINER_USER $Name bash

    Write-BoxerInfo "Shell exited. Container '$Name' is still running."
    Write-BoxerInfo "  Re-enter:  boxer start $Name"
    Write-BoxerInfo "  Claude:    boxer claude $Name"
    Write-BoxerInfo "  Stop:      boxer stop $Name"
}

# ── Shared boot sequence (used by start and claude commands) ──

function Initialize-BoxerContainer {
    param([string]$Name)

    Assert-DockerRunning
    Assert-BoxerContainer $Name

    # Start the container if not running
    $status = Get-ContainerStatus $Name
    Write-BoxerDebug "Current container status: $status"
    if ($status -ne "running") {
        Write-BoxerInfo "Starting container '$Name'..."
        $startOutput = docker start $Name 2>&1
        $startExit = $LASTEXITCODE
        Write-BoxerDebug "docker start exit=$startExit output=$startOutput"

        if ($startExit -ne 0) {
            Write-BoxerError "docker start failed (exit=$startExit): $startOutput"
            Write-BoxerInfo "Dumping container logs:"
            docker logs --tail 50 $Name 2>&1 | ForEach-Object { Write-BoxerDiag "  $_" }
            Stop-BoxerWithError "Container '$Name' failed to start."
        }

        # Wait for entrypoint to finish firewall setup
        Write-BoxerInfo "Waiting for container to be ready..."
        $waited = 0
        while ($true) {
            $currentStatus = Get-ContainerStatus $Name
            if ($currentStatus -ne "running") {
                Write-BoxerError "Container exited unexpectedly (status: $currentStatus) while waiting for readiness"
                Write-BoxerInfo "Container logs:"
                docker logs --tail 80 $Name 2>&1 | ForEach-Object { Write-BoxerDiag "  $_" }
                $inspectJson = docker inspect --format '{{.State.ExitCode}} | OOMKilled={{.State.OOMKilled}} | Error={{.State.Error}}' $Name 2>&1
                Write-BoxerDiag "Container state: $inspectJson"
                Stop-BoxerWithError "Container '$Name' died during startup. See logs above."
            }

            $null = docker exec $Name test -f /tmp/.boxer-ready 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-BoxerDebug "Readiness signal detected after $([math]::Round($waited * 0.2, 1))s"
                break
            }
            Start-Sleep -Milliseconds 200
            $waited++
            if ($waited -ge 50) {
                Write-BoxerWarn "Container readiness timed out after 10s, proceeding anyway"
                Write-BoxerDiag "Container is running but /tmp/.boxer-ready not found"
                Write-BoxerInfo "Container logs so far:"
                docker logs --tail 30 $Name 2>&1 | ForEach-Object { Write-BoxerDiag "  $_" }
                break
            }
        }
    } else {
        Write-BoxerDebug "Container already running, skipping start"
    }

    # Verify container is running before syncing
    $preCredStatus = Get-ContainerStatus $Name
    Write-BoxerDebug "Pre-credential-sync status: $preCredStatus"
    if ($preCredStatus -ne "running") {
        Write-BoxerError "Container is not running (status: $preCredStatus) — cannot sync credentials"
        docker logs --tail 50 $Name 2>&1 | ForEach-Object { Write-BoxerDiag "  $_" }
        Stop-BoxerWithError "Container '$Name' exited before credential sync."
    }

    # Ensure ~/.claude directory exists for config sync
    docker exec $Name mkdir -p "$($script:BOXER_CONTAINER_HOME)/.claude" 2>&1 | Out-Null

    # Keep claude-switch.py (cs) up to date inside the container
    Sync-BoxerClaudeSwitcher $Name

    # Freshen host's active profile before syncing (captures token rotation)
    Invoke-BoxerFreshenHostProfile

    # Sync Claude Code config (rules, settings, agents, profiles, etc.)
    Sync-BoxerClaudeConfig $Name

    # Sync ~/.claude.json (onboarding state, user metadata) so Claude Code
    # doesn't trigger a first-run login flow inside the container.
    Sync-BoxerClaudeJson $Name

    # Auto-apply host's active profile in containers without credentials
    Apply-InitialProfile $Name
}

# Update claude-switch.py and the cs wrapper in the container from the host's copy
function Sync-BoxerClaudeSwitcher {
    param([string]$Name)

    $csSrc = Join-Path $script:BOXER_ROOT "claude-switch.py"
    if (-not (Test-Path $csSrc)) { return }

    docker cp $csSrc "${Name}:/usr/local/bin/claude-switch.py"

    docker exec $Name bash -c 'printf "#!/bin/sh\nexec python3 /usr/local/bin/claude-switch.py \"\$@\"\n" > /usr/local/bin/cs && chmod +x /usr/local/bin/claude-switch.py /usr/local/bin/cs'

    docker exec $Name chown "$($script:BOXER_CONTAINER_USER):$($script:BOXER_CONTAINER_USER)" `
        /usr/local/bin/claude-switch.py /usr/local/bin/cs 2>&1 | Out-Null
}

# Freshen the host's active profile so synced tokens are current
function Invoke-BoxerFreshenHostProfile {
    $csScript = Join-Path $script:BOXER_ROOT "claude-switch.py"
    if (-not (Test-Path $csScript)) { return }

    $py = Resolve-HostPython
    if (-not $py) { return }

    & $py $csScript freshen --quiet 2>&1 | Out-Null
}

function Sync-BoxerClaudeConfig {
    param([string]$Name)

    $syncEnabled = Get-BoxerConfig -Section "sync" -Key "claude_config" -Default "true"
    if ($syncEnabled -ne "true") { return }

    $srcDir = Join-Path $HOME ".claude"
    if (-not (Test-Path $srcDir)) { return }

    $destDir = "$($script:BOXER_CONTAINER_HOME)/.claude"

    Write-BoxerInfo "Syncing Claude Code config into container..."

    # Individual files to sync
    $files = @("CLAUDE.md", "settings.json", "settings.local.json", "keybindings.json")
    foreach ($f in $files) {
        $filePath = Join-Path $srcDir $f
        if (Test-Path $filePath) {
            docker cp $filePath "${Name}:${destDir}/$f"
        }
    }

    # Directories to sync (entire trees)
    $dirs = @("rules", "agents", "commands", "skills", "hooks", "ecc", "plugins", "profiles")
    foreach ($d in $dirs) {
        $dirPath = Join-Path $srcDir $d
        if (Test-Path $dirPath) {
            # Remove stale copy, then copy fresh
            docker exec $Name rm -rf "$destDir/$d" 2>&1 | Out-Null
            docker cp $dirPath "${Name}:${destDir}/$d"
        }
    }

    # Remove host's .active marker — each container tracks its own active profile
    docker exec $Name rm -f "$destDir/profiles/.active" 2>&1 | Out-Null

    # Fix ownership for everything we just copied
    docker exec $Name chown -R "$($script:BOXER_CONTAINER_USER):$($script:BOXER_CONTAINER_USER)" $destDir 2>&1 | Out-Null

    # Restrict profile file permissions (contain OAuth refresh tokens)
    docker exec $Name find "$destDir/profiles" -name '*.json' -exec chmod 600 {} + 2>&1 | Out-Null
}

# Sync ~/.claude.json from the host into the container.
# This file lives at $HOME/.claude.json (not inside ~/.claude/) and contains
# onboarding flags (hasCompletedOnboarding, userID, etc.) that Claude Code
# checks on startup. Without it, Claude triggers its first-run login flow
# even when valid OAuth tokens are present in .credentials.json.
# The oauthAccount key is intentionally left for cs use to overwrite with
# the correct profile's credentials via its merge-write.
function Sync-BoxerClaudeJson {
    param([string]$Name)

    $src = Join-Path $HOME ".claude.json"
    if (-not (Test-Path $src)) { return }

    $dest = "$($script:BOXER_CONTAINER_HOME)/.claude.json"

    docker cp $src "${Name}:${dest}"
    docker exec $Name chown "$($script:BOXER_CONTAINER_USER):$($script:BOXER_CONTAINER_USER)" $dest 2>&1 | Out-Null
    docker exec $Name chmod 600 $dest 2>&1 | Out-Null
}

# Auto-apply the host's active profile when a container has no credentials yet.
# This handles the common flow: cs use <profile> on host → boxer claude <name>.
function Apply-InitialProfile {
    param([string]$Name)

    $credsFile = "$($script:BOXER_CONTAINER_HOME)/.claude/.credentials.json"

    # Skip if container already has credentials
    $null = docker exec $Name test -f $credsFile 2>&1
    if ($LASTEXITCODE -eq 0) { return }

    # Read host's active profile name
    $hostActive = Join-Path $HOME ".claude" "profiles" ".active"
    if (-not (Test-Path $hostActive)) { return }

    try {
        $activeData = Get-Content $hostActive -Raw | ConvertFrom-Json
        $activeProfile = $activeData.profile
    } catch {
        return
    }

    if ([string]::IsNullOrWhiteSpace($activeProfile)) { return }

    Write-BoxerInfo "Applying profile '$activeProfile' to new container..."
    docker exec --user $script:BOXER_CONTAINER_USER $Name bash -c "command -v cs >/dev/null 2>&1 && cs use $activeProfile" 2>&1 | Out-Null
}
