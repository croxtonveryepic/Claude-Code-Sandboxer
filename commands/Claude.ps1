# boxer claude - Launch Claude Code inside a container

function Invoke-BoxerClaude {
    param(
        [Parameter(Position = 0)]
        [string]$Name,

        [switch]$Resume,
        [switch]$Print,
        [string]$Prompt,
        [string]$Model,
        [switch]$Help
    )

    if ($Help) {
        Write-Host @"
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
"@
        return
    }

    if ([string]::IsNullOrWhiteSpace($Name)) {
        Stop-BoxerWithError "Usage: boxer claude <name>"
    }

    # Shared boot: start container, wait for readiness, sync creds+config
    # (Initialize-BoxerContainer is defined in Start.ps1, loaded before this)
    Initialize-BoxerContainer $Name

    # Final check: is the container still alive?
    $preLaunchStatus = Get-ContainerStatus $Name
    Write-BoxerDebug "Pre-launch status: $preLaunchStatus"
    if ($preLaunchStatus -ne "running") {
        Write-BoxerError "Container died between sync and launch (status: $preLaunchStatus)"
        docker logs --tail 80 $Name 2>&1 | ForEach-Object { Write-BoxerDiag "  $_" }
        Stop-BoxerWithError "Container '$Name' is not running. See logs above."
    }

    $workspace = Get-ContainerLabel -Name $Name -Label "boxer.workspace"

    # Build Claude CLI args
    $claudeArgs = @()
    if ($Resume) { $claudeArgs += "--resume" }
    if ($Print)  { $claudeArgs += "--print" }
    if (-not [string]::IsNullOrWhiteSpace($Prompt)) {
        $claudeArgs += "-p"
        $claudeArgs += $Prompt
    }
    if (-not [string]::IsNullOrWhiteSpace($Model)) {
        $claudeArgs += "--model"
        $claudeArgs += $Model
    }

    # Pre-session: freshen the container's active profile (captures any
    # prior rotation that was never saved)
    docker exec --user $script:BOXER_CONTAINER_USER $Name `
        bash -c 'command -v cs >/dev/null 2>&1 && cs freshen --quiet' 2>&1 | Out-Null

    # Launch Claude Code CLI
    Write-BoxerInfo "Launching Claude Code in '$Name'..."
    $execCmd = @("exec", "-it", "-w", $workspace, "--user", $script:BOXER_CONTAINER_USER, $Name, "claude", "--dangerously-skip-permissions") + $claudeArgs
    Write-BoxerDebug "docker $($execCmd -join ' ')"
    & docker @execCmd

    # Post-session: capture any token rotation from the Claude session
    Write-BoxerInfo "Capturing credential state..."
    docker exec --user $script:BOXER_CONTAINER_USER $Name `
        bash -c 'command -v cs >/dev/null 2>&1 && cs freshen --quiet' 2>&1 | Out-Null

    # Pull freshened profile back to host
    # (Pull-ContainerProfiles is defined in Credential.ps1, loaded by the dispatcher)
    if (Get-Command Pull-ContainerProfiles -ErrorAction SilentlyContinue) {
        try { Pull-ContainerProfiles $Name } catch {}
    }

    Write-BoxerInfo "Claude session ended. Container '$Name' is still running."
    Write-BoxerInfo "  Re-enter:  boxer claude $Name"
    Write-BoxerInfo "  Shell:     boxer start $Name"
    Write-BoxerInfo "  Stop:      boxer stop $Name"
}
