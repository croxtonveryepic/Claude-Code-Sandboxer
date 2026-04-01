FROM docker/sandbox-templates:claude-code

USER root

# Install iptables for network firewall
RUN apt-get update \
    && apt-get install -y --no-install-recommends iptables \
    && rm -rf /var/lib/apt/lists/*

# Strip unnecessary group memberships (docker, sudo) from agent user.
# These serve no purpose in a locked-down sandbox and widen the attack
# surface if configuration changes (e.g. Docker socket mounted).
RUN usermod -G agent agent

# Copy entrypoint and firewall scripts
COPY firewall-init.sh /usr/local/bin/firewall-init.sh
COPY entrypoint.sh /usr/local/bin/boxer-entrypoint.sh
COPY copy-ssh-keys.sh /usr/local/bin/copy-ssh-keys.sh
RUN chmod +x /usr/local/bin/firewall-init.sh /usr/local/bin/boxer-entrypoint.sh /usr/local/bin/copy-ssh-keys.sh

# Install Claude Switcher (cs) for per-container account switching
COPY claude-switch.py /usr/local/bin/claude-switch.py
RUN printf '#!/bin/sh\nexec python3 /usr/local/bin/claude-switch.py "$@"\n' > /usr/local/bin/cs \
    && chmod +x /usr/local/bin/claude-switch.py /usr/local/bin/cs

WORKDIR /home/agent

ENTRYPOINT ["/usr/local/bin/boxer-entrypoint.sh"]
CMD ["sleep", "infinity"]
