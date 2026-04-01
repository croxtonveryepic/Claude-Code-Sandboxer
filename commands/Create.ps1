# boxer create - Create a new sandbox container

function Invoke-BoxerCreate {
    param(
        [Parameter(Position = 0)]
        [string]$RepoPath,

        [Parameter(Position = 1)]
        [string]$Name,

        [string]$Cpu,
        [string]$Memory,
        [string]$Network,
        [switch]$NoSsh,
        [switch]$NoGitConfig,
        [string[]]$Env = @(),
        [string]$Domains,
        [switch]$Start,
        [switch]$Help
    )

    if ($Help) {
        Write-Host @"
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
"@
        return
    }

    if ([string]::IsNullOrWhiteSpace($RepoPath) -or [string]::IsNullOrWhiteSpace($Name)) {
        Stop-BoxerWithError "Usage: boxer create <repo-path> <name> [options]"
    }

    # Apply config defaults
    if ([string]::IsNullOrWhiteSpace($Cpu))     { $Cpu     = Get-BoxerConfig "defaults" "cpu"     $script:BOXER_DEFAULT_CPU }
    if ([string]::IsNullOrWhiteSpace($Memory))  { $Memory  = Get-BoxerConfig "defaults" "memory"  $script:BOXER_DEFAULT_MEMORY }
    if ([string]::IsNullOrWhiteSpace($Network)) { $Network = Get-BoxerConfig "defaults" "network" $script:BOXER_DEFAULT_NETWORK }

    $mountSsh = if ($NoSsh) { "false" } else { Get-BoxerConfig "mounts" "ssh" "true" }
    $mountGitconfig = if ($NoGitConfig) { "false" } else { Get-BoxerConfig "mounts" "gitconfig" "true" }

    if ([string]::IsNullOrWhiteSpace($Domains)) {
        $Domains = Get-BoxerConfig "firewall" "extra_domains" ""
    }

    Assert-DockerRunning
    Assert-ValidName $Name

    if (Test-ContainerExists $Name) {
        Stop-BoxerWithError "Container '$Name' already exists. Choose a different name or run 'boxer rm $Name' first."
    }

    # Resolve repo path
    if (-not (Test-Path $RepoPath -PathType Container)) {
        Stop-BoxerWithError "Repository path does not exist: $RepoPath"
    }
    $dockerRepoPath = ConvertTo-DockerPath $RepoPath

    # Ensure the boxer image is built
    Initialize-BoxerImage

    Write-BoxerInfo "Creating container '$Name'..."
    Write-BoxerInfo "  Repo: $dockerRepoPath"
    Write-BoxerInfo "  CPU: $Cpu | Memory: $Memory | Network: $Network"

    # Build docker create command
    $cmd = @(
        "create"
        "--name", $Name
        # Labels
        "--label", "boxer.managed=true"
        "--label", "boxer.repo.path=$dockerRepoPath"
        "--label", "boxer.created.at=$((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))"
        "--label", "boxer.version=$($script:BOXER_VERSION)"
        "--label", "boxer.network=$Network"
        # Resource limits
        "--cpus", $Cpu
        "--memory", $Memory
        # Security
        "--cap-add", "NET_ADMIN"
        "--security-opt", "no-new-privileges"
        # Repo mount
        "-v", "${dockerRepoPath}:$($script:BOXER_CONTAINER_WORKSPACE)"
        # Claude config persistence via named volumes
        "-v", "$($script:BOXER_VOLUME_PREFIX)-${Name}-claude-config:$($script:BOXER_CONTAINER_HOME)/.claude"
        "-v", "$($script:BOXER_VOLUME_PREFIX)-${Name}-claude-data:$($script:BOXER_CONTAINER_HOME)/.local/share/claude"
    )

    # SSH keys — mount to a staging directory so entrypoint can copy with
    # correct permissions. Direct bind-mount via 9p exposes keys as 777.
    $sshDir = Join-Path $HOME ".ssh"
    if ($mountSsh -eq "true") {
        if (Test-Path $sshDir) {
            $cmd += "-v"
            $cmd += "${sshDir}:/root/.ssh-staging:ro"
        }
        else {
            Write-BoxerWarn "~/.ssh not found, skipping SSH mount"
        }
    }

    # Git config (read-only)
    $gitconfigFile = Join-Path $HOME ".gitconfig"
    if ($mountGitconfig -eq "true") {
        if (Test-Path $gitconfigFile) {
            $cmd += "-v"
            $cmd += "${gitconfigFile}:$($script:BOXER_CONTAINER_HOME)/.gitconfig:ro"
        }
        else {
            Write-BoxerWarn "~/.gitconfig not found, skipping git config mount"
        }
    }

    # Environment: override Windows-specific git settings for Linux container
    $cmd += "-e", "GIT_SSH_COMMAND=ssh"
    $cmd += "-e", "GIT_CONFIG_COUNT=1"
    $cmd += "-e", "GIT_CONFIG_KEY_0=core.autocrlf"
    $cmd += "-e", "GIT_CONFIG_VALUE_0=input"
    $cmd += "-e", "BOXER_CONTAINER=true"
    $cmd += "-e", "BOXER_CONTAINER_NAME=$Name"
    $cmd += "-e", "BOXER_REPO_NAME=$(Split-Path $RepoPath -Leaf)"

    # Extra firewall domains
    if (-not [string]::IsNullOrWhiteSpace($Domains)) {
        $cmd += "-e", "BOXER_EXTRA_DOMAINS=$Domains"
    }

    # Network mode
    switch ($Network) {
        "restricted" { <# Default bridge, firewall handles restriction #> }
        "none"       { $cmd += "--network", "none" }
        "host"       { $cmd += "--network", "host" }
        default      { Stop-BoxerWithError "Invalid network mode: $Network. Use: restricted, none, host" }
    }

    # Extra user-provided environment variables
    foreach ($envVar in $Env) {
        $cmd += "-e", $envVar
    }

    # Interactive/TTY support
    $cmd += "-it"

    # Image
    $cmd += $script:BOXER_IMAGE

    # Execute
    $null = & docker @cmd
    if ($LASTEXITCODE -ne 0) {
        Stop-BoxerWithError "Failed to create container '$Name'."
    }
    Write-BoxerSuccess "Container '$Name' created."

    if ($Start) {
        . "$script:BOXER_ROOT\commands\Start.ps1"
        Invoke-BoxerStart -Name $Name
    }
}
