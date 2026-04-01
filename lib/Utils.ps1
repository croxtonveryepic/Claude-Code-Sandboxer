# Boxer shared utilities: logging, path conversion, validation

# --- Logging ---

function Write-BoxerInfo {
    param([string]$Message)
    Write-Host "[boxer] " -ForegroundColor Blue -NoNewline
    Write-Host $Message
}

function Write-BoxerSuccess {
    param([string]$Message)
    Write-Host "[boxer] " -ForegroundColor Green -NoNewline
    Write-Host $Message
}

function Write-BoxerWarn {
    param([string]$Message)
    Write-Host "[boxer] " -ForegroundColor Yellow -NoNewline
    Write-Host $Message
}

function Write-BoxerDebug {
    param([string]$Message)
    if ($env:BOXER_DEBUG -eq "1" -or $script:BoxerVerbose) {
        Write-Host "[boxer:debug] " -ForegroundColor DarkGray -NoNewline
        Write-Host $Message -ForegroundColor DarkGray
    }
}

function Write-BoxerDiag {
    # Like debug but always prints — used in error/diagnostic paths
    param([string]$Message)
    Write-Host "[boxer:diag] " -ForegroundColor DarkYellow -NoNewline
    Write-Host $Message
}

function Write-BoxerError {
    param([string]$Message)
    Write-Host "[boxer] " -ForegroundColor Red -NoNewline
    Write-Host $Message
}

function Stop-BoxerWithError {
    param([string]$Message)
    Write-BoxerError $Message
    exit 1
}

# --- Path Conversion ---

function ConvertTo-DockerPath {
    param([string]$Path)

    # Resolve to full absolute path
    $resolved = (Resolve-Path -Path $Path -ErrorAction Stop).Path

    # PowerShell returns Windows paths like C:\Users\...
    # Docker Desktop on Windows accepts C:/Users/... or C:\Users\...
    # Return as-is since Docker Desktop handles Windows paths
    return $resolved
}

# --- Validation ---

function Assert-DockerRunning {
    $null = docker info 2>&1
    if ($LASTEXITCODE -ne 0) {
        Stop-BoxerWithError "Docker is not running. Start Docker Desktop and try again."
    }
}

function Assert-ValidName {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        Stop-BoxerWithError "Container name is required."
    }

    if ($Name -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$') {
        Stop-BoxerWithError "Invalid container name '$Name'. Use alphanumeric characters, hyphens, and underscores (1-64 chars, must start with alphanumeric)."
    }
}

function Test-BoxerContainer {
    param([string]$Name)

    $label = docker inspect --format '{{index .Config.Labels "boxer.managed"}}' $Name 2>&1
    if ($LASTEXITCODE -ne 0) { return $false }
    return $label -eq "true"
}

function Test-ContainerExists {
    param([string]$Name)

    $null = docker inspect $Name 2>&1
    return $LASTEXITCODE -eq 0
}

function Assert-BoxerContainer {
    param([string]$Name)

    if (-not (Test-ContainerExists $Name)) {
        Stop-BoxerWithError "Container '$Name' does not exist. Run 'boxer list' to see available containers."
    }

    if (-not (Test-BoxerContainer $Name)) {
        Stop-BoxerWithError "Container '$Name' exists but is not managed by boxer."
    }
}

function Get-ContainerStatus {
    param([string]$Name)

    $status = docker inspect --format '{{.State.Status}}' $Name 2>&1
    if ($LASTEXITCODE -ne 0) { return $null }
    return $status.Trim()
}

# --- Python Resolution ---

function Resolve-HostPython {
    <#
    .SYNOPSIS
        Return the name of a working host-side Python 3 command,
        skipping the Windows Store stub (WindowsApps/python3.exe).
    #>
    foreach ($cmd in @("python3", "python")) {
        $found = Get-Command $cmd -ErrorAction SilentlyContinue
        if ($found -and $found.Source -notmatch 'WindowsApps') {
            return $cmd
        }
    }
    return $null
}
