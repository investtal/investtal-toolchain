# 9cc sandbox image — isolates Claude Code from the host filesystem.
# Build context must include: claude-local, claude, investtal, proto, prototools,
# zshrc, zshenv, agent-proxy.mjs, sandbox-entrypoint.sh.
FROM node:24-slim

# Baseline dev tools and zsh (Claude Code shell workflows expect these).
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       git ca-certificates curl less jq gh zsh \
    && rm -rf /var/lib/apt/lists/*

# Install proto (moonrepo toolchain manager) from scratch.
ENV PROTO_HOME=/home/9cc/.proto
RUN curl -fsSL https://moonrepo.dev/install/proto.sh | bash
ENV PATH="/home/9cc/.proto/bin:${PATH}"

# Dynamic runtime user: the container is started with --user $(id -u):$(id -g).
# Create a globally writable home directory so the dynamic user has a HOME.
RUN mkdir -p /home/9cc && chmod 777 /home/9cc

# Copy Claude Code binary from the host (not npm install).
COPY claude-local /home/9cc/.claude/local

# Copy team context and Claude plugins/skills from the build context.
# These are copied at build time, not mounted at runtime, so host paths stay hidden.
COPY claude /home/9cc/.claude
COPY investtal /home/9cc/.investtal
COPY proto /home/9cc/.proto
COPY prototools /home/9cc/.prototools

# Copy zsh config if the host provided it; otherwise create minimal files.
COPY zshrc /home/9cc/.zshrc
COPY zshenv /home/9cc/.zshenv

# Copy the logging proxy and container entrypoint.
COPY agent-proxy.mjs /home/9cc/agent-proxy.mjs
COPY sandbox-entrypoint.sh /home/9cc/sandbox-entrypoint.sh
RUN chmod +x /home/9cc/sandbox-entrypoint.sh

ENV HOME=/home/9cc
ENV SHELL=/usr/bin/zsh

WORKDIR /workspace
ENTRYPOINT ["/home/9cc/sandbox-entrypoint.sh"]
CMD ["claude"]
