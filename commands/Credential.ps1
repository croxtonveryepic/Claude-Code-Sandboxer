# boxer credential - Manage Claude credentials and switcher across containers

function Resolve-ClaudeSwitchScript {
    $script = Join-Path $script:BOXER_ROOT "claude-switch.py"
    if (Test-Path $script) { return $script }
    return $null
}

function Invoke-BoxerCredential {
    param(
        [Parameter(Position = 0)]
        [string]$SubCommand,

        [Parameter(Position = 1)]
        [string]$Name,

        [switch]$Help
    )

    if ($Help -or [string]::IsNullOrWhiteSpace($SubCommand)) {
        Write-Host @"
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
"@
        return
    }

    switch ($SubCommand) {
        "sync"    { Invoke-BoxerCredentialSync -TargetName $Name }
        "pull"    { Invoke-BoxerCredentialPull }
        "freshen" { Invoke-BoxerCredentialFreshen }
        "install" { Invoke-BoxerCredentialInstall -Name $Name }
        default   { Stop-BoxerWithError "Unknown subcommand: $SubCommand. Run 'boxer credential --help' for usage." }
    }
}

# ── Freshen (host-side) ─────────────────────────────────────────────

function Invoke-BoxerCredentialFreshen {
    $csScript = Resolve-ClaudeSwitchScript
    if (-not $csScript) {
        Stop-BoxerWithError "claude-switch.py not found at $(Join-Path $script:BOXER_ROOT 'claude-switch.py')"
    }

    $py = Resolve-HostPython
    if (-not $py) {
        Stop-BoxerWithError "Python not found. Install Python 3 and ensure 'python' is on PATH."
    }

    Write-BoxerInfo "Freshening host active profile..."
    & $py $csScript freshen
}

# ── Pull from containers ────────────────────────────────────────────

# Read token_updated_at from a profile JSON file, normalising Z -> +00:00.
# Returns the timestamp string, or the epoch fallback on error.
function Read-ProfileTimestamp {
    param([string]$FilePath)
    $py = Resolve-HostPython
    if (-not $py) { return "1970-01-01T00:00:00+00:00" }
    $result = & $py -c @"
import json, sys
d = json.load(open(sys.argv[1], 'r'))
ts = d.get('token_updated_at', '1970-01-01T00:00:00+00:00')
if ts.endswith('Z'):
    ts = ts[:-1] + '+00:00'
print(ts)
"@ $FilePath 2>&1
    if ($LASTEXITCODE -ne 0) { return "1970-01-01T00:00:00+00:00" }
    return "$result".Trim()
}

function Pull-ContainerProfiles {
    param([string]$Name)

    $hostProfilesDir = Join-Path $HOME ".claude" "profiles"
    $containerProfilesDir = "$($script:BOXER_CONTAINER_HOME)/.claude/profiles"

    # Freshen the container's active profile first
    docker exec --user $script:BOXER_CONTAINER_USER $Name `
        bash -c 'command -v cs >/dev/null 2>&1 && cs freshen --quiet' 2>&1 | Out-Null

    # Create temp dir for pulling
    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "boxer-pull-$Name-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

    try {
        # Copy container profiles to temp dir
        $cpOutput = docker cp "${Name}:${containerProfilesDir}/." "$tmpDir/" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-BoxerInfo "  ${Name}: no profiles to pull"
            return
        }

        # Merge each profile by timestamp
        $updated = 0
        $profileFiles = Get-ChildItem -Path $tmpDir -Filter "*.json" -ErrorAction SilentlyContinue
        foreach ($containerFile in $profileFiles) {
            $hostFile = Join-Path $hostProfilesDir $containerFile.Name
            $profileName = [System.IO.Path]::GetFileNameWithoutExtension($containerFile.Name)

            $containerTs = Read-ProfileTimestamp $containerFile.FullName
            if ($containerTs -eq "1970-01-01T00:00:00+00:00" -and $LASTEXITCODE -ne 0) { continue }

            if (-not (Test-Path $hostFile)) {
                # New profile from container — adopt it
                Copy-Item $containerFile.FullName $hostFile
                $updated++
                Write-BoxerInfo "  ${Name}: new profile '$profileName' pulled"
                continue
            }

            $hostTs = Read-ProfileTimestamp $hostFile
            if ($hostTs -eq "1970-01-01T00:00:00+00:00" -and $LASTEXITCODE -ne 0) { continue }

            # INVARIANT: Both timestamps are produced by claude-switch.py's now_iso(),
            # which always outputs UTC with +00:00 offset. Read-ProfileTimestamp
            # normalises any trailing "Z" to "+00:00", so string comparison
            # is equivalent to chronological ordering.
            if ($containerTs -gt $hostTs) {
                Copy-Item $containerFile.FullName $hostFile -Force
                $updated++
                Write-BoxerInfo "  ${Name}: profile '$profileName' updated (container token is newer)"
            }
        }

        if ($updated -eq 0) {
            Write-BoxerInfo "  ${Name}: all profiles current"
        }
    }
    finally {
        Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-BoxerCredentialPull {
    Assert-DockerRunning

    $containers = docker ps -a --filter "label=boxer.managed=true" --format '{{.Names}}' 2>&1
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($containers)) {
        Write-BoxerInfo "No boxer containers found."
        return
    }

    # Ensure host profiles dir exists
    $hostProfilesDir = Join-Path $HOME ".claude" "profiles"
    if (-not (Test-Path $hostProfilesDir)) {
        New-Item -ItemType Directory -Path $hostProfilesDir -Force | Out-Null
    }

    $containerList = $containers -split "`n" | Where-Object { $_.Trim() -ne "" }
    $total = 0
    $pulled = 0
    $skipped = 0

    foreach ($name in $containerList) {
        $name = $name.Trim()
        $total++

        $status = Get-ContainerStatus $name
        if ($status -ne "running") {
            Write-BoxerInfo "  ${name}: skipped (${status})"
            $skipped++
            continue
        }

        # Check if cs is installed
        $null = docker exec $name test -f /usr/local/bin/cs 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-BoxerInfo "  ${name}: skipped (Claude Switcher not installed)"
            $skipped++
            continue
        }

        try { Pull-ContainerProfiles $name } catch {
            Write-BoxerWarn "  ${name}: pull failed (non-fatal)"
        }
        $pulled++
    }

    Write-BoxerSuccess "Pull complete: $pulled pulled, $skipped skipped (of $total total)"
}

# ── Sync (pull-then-push) ───────────────────────────────────────────

function Invoke-BoxerCredentialSync {
    param(
        [string]$TargetName
    )

    Assert-DockerRunning

    # Validate target container if specified
    if (-not [string]::IsNullOrWhiteSpace($TargetName)) {
        Assert-BoxerContainer $TargetName
        $targetStatus = Get-ContainerStatus $TargetName
        if ($targetStatus -ne "running") {
            Stop-BoxerWithError "Container '$TargetName' is not running (status: $targetStatus). Start it first with: boxer start $TargetName"
        }
    }

    # Phase 1: Freshen host active profile
    $csScript = Resolve-ClaudeSwitchScript
    $py = Resolve-HostPython
    if ($csScript -and $py) {
        Write-BoxerInfo "Freshening host active profile..."
        & $py $csScript freshen --quiet 2>&1 | Out-Null
    }

    if (-not [string]::IsNullOrWhiteSpace($TargetName)) {
        $containerList = @($TargetName)
    } else {
        $containers = docker ps -a --filter "label=boxer.managed=true" --format '{{.Names}}' 2>&1
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($containers)) {
            Write-BoxerInfo "No boxer containers found."
            return
        }
        $containerList = $containers -split "`n" | Where-Object { $_.Trim() -ne "" }
    }

    # Phase 2: Pull from running containers
    Write-BoxerInfo "Pulling profiles from containers..."
    $hostProfilesDir = Join-Path $HOME ".claude" "profiles"
    if (-not (Test-Path $hostProfilesDir)) {
        New-Item -ItemType Directory -Path $hostProfilesDir -Force | Out-Null
    }

    foreach ($name in $containerList) {
        $name = "$name".Trim()
        $status = Get-ContainerStatus $name
        if ($status -eq "running") {
            $null = docker exec $name test -f /usr/local/bin/cs 2>&1
            if ($LASTEXITCODE -eq 0) {
                try { Pull-ContainerProfiles $name } catch {}
            }
        }
    }

    # Phase 3: Push to containers
    Write-BoxerInfo "Pushing profiles to containers..."

    $total = 0
    $synced = 0
    $skipped = 0

    foreach ($name in $containerList) {
        $name = "$name".Trim()
        $total++

        $status = Get-ContainerStatus $name
        if ($status -ne "running") {
            Write-BoxerInfo "  ${name}: skipped (${status}, will sync on next start)"
            $skipped++
            continue
        }

        Write-BoxerInfo "  ${name}: pushing..."

        # Ensure ~/.claude directory exists
        docker exec $name mkdir -p "$($script:BOXER_CONTAINER_HOME)/.claude" 2>&1 | Out-Null

        # Sync profiles and Claude Code config
        try { Sync-BoxerClaudeConfig $name } catch { Write-BoxerWarn "  ${name}: config sync failed (non-fatal)" }
        try { Set-BoxerCredentialPermissions $name } catch {}

        if ($csScript) {
            try { Install-ClaudeSwitcher -Name $name -ScriptPath $csScript } catch {
                Write-BoxerWarn "  ${name}: Claude Switcher install failed (non-fatal)"
            }
        }

        $synced++
    }

    Write-BoxerSuccess "Credential sync complete: $synced synced, $skipped skipped (of $total total)"
}

# ── Install ──────────────────────────────────────────────────────────

function Invoke-BoxerCredentialInstall {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        Stop-BoxerWithError "Usage: boxer credential install <name>"
    }

    Assert-DockerRunning
    Assert-BoxerContainer $Name

    $status = Get-ContainerStatus $Name
    if ($status -ne "running") {
        Stop-BoxerWithError "Container '$Name' is not running (status: $status). Start it first with: boxer start $Name"
    }

    $csScript = Resolve-ClaudeSwitchScript
    if (-not $csScript) {
        Stop-BoxerWithError "claude-switch.py not found at $(Join-Path $script:BOXER_ROOT 'claude-switch.py')"
    }

    Install-ClaudeSwitcher -Name $Name -ScriptPath $csScript
    Write-BoxerSuccess "Claude Switcher installed in '$Name'. Use 'cs status' inside the container."
}

function Install-ClaudeSwitcher {
    param(
        [string]$Name,
        [string]$ScriptPath
    )

    docker cp "$ScriptPath" "${Name}:/usr/local/bin/claude-switch.py"

    docker exec $Name bash -c '
        printf "#!/bin/sh\nexec python3 /usr/local/bin/claude-switch.py \"\$@\"\n" > /usr/local/bin/cs
        chmod +x /usr/local/bin/claude-switch.py /usr/local/bin/cs
    '

    docker exec $Name chown "$($script:BOXER_CONTAINER_USER):$($script:BOXER_CONTAINER_USER)" `
        /usr/local/bin/claude-switch.py /usr/local/bin/cs 2>&1 | Out-Null
}

function Set-BoxerCredentialPermissions {
    param([string]$Name)

    $destDir = "$($script:BOXER_CONTAINER_HOME)/.claude"

    docker exec $Name bash -c @"
        if [ -d '$destDir/profiles' ]; then
            find '$destDir/profiles' -name '*.json' -exec chmod 600 {} + 2>/dev/null || true
        fi
"@ 2>&1 | Out-Null
}
