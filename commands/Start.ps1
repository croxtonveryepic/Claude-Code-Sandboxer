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

    Write-BoxerInfo "Opening shell in '$Name'..."
    docker exec -it --user $script:BOXER_CONTAINER_USER $Name bash

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

    # Sync Claude Code config (rules, settings, agents, profiles, etc.)
    Sync-BoxerClaudeConfig $Name
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
