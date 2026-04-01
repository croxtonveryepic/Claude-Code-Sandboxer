#!/usr/bin/env bash
# Boxer constants and defaults

BOXER_VERSION="1.0.0"
BOXER_LABEL_PREFIX="boxer"
BOXER_IMAGE="boxer:latest"

# Default resource limits
BOXER_DEFAULT_CPU="4"
BOXER_DEFAULT_MEMORY="8g"
BOXER_DEFAULT_NETWORK="restricted"

# Container paths
BOXER_CONTAINER_USER="agent"
BOXER_CONTAINER_HOME="/home/agent"

# Volume name prefix
BOXER_VOLUME_PREFIX="boxer"

# Claude Switcher script path (relative to BOXER_ROOT's parent)
BOXER_CLAUDE_SWITCH_SCRIPT=""  # Resolved at runtime in credential.sh
