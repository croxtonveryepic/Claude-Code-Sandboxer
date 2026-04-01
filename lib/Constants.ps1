# Boxer constants and defaults

$script:BOXER_VERSION = "1.0.0"
$script:BOXER_LABEL_PREFIX = "boxer"
$script:BOXER_IMAGE = "boxer:latest"

# Default resource limits
$script:BOXER_DEFAULT_CPU = "4"
$script:BOXER_DEFAULT_MEMORY = "8g"
$script:BOXER_DEFAULT_NETWORK = "restricted"

# Container paths
$script:BOXER_CONTAINER_USER = "agent"
$script:BOXER_CONTAINER_HOME = "/home/agent"

# Volume name prefix
$script:BOXER_VOLUME_PREFIX = "boxer"

# Claude Switcher script path (resolved at runtime in Credential.ps1)
$script:BOXER_CLAUDE_SWITCH_SCRIPT = ""
