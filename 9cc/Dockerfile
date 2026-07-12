# 9cc sandbox image — isolates Claude Code from the host filesystem.
# Build context must include: claude-local, claude-source.mode, claude, investtal, proto,
# prototools, zshrc, zshenv, agent-proxy.mjs, sandbox-entrypoint.sh.
FROM node:24-slim

# Baseline dev tools and zsh (Claude Code shell workflows expect these).
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       git ca-certificates curl less jq zsh \
    && rm -rf /var/lib/apt/lists/*

# Install proto (moonrepo toolchain manager) from scratch.
ENV PROTO_HOME=/home/9cc/.proto
RUN curl -fsSL https://moonrepo.dev/install/proto.sh | bash
ENV PATH="/home/9cc/.proto/bin:${PATH}"

# Dynamic runtime user: the container is started with --user $(id -u):$(id -g).
# Create a globally writable home directory so the dynamic user has a HOME.
RUN mkdir -p /home/9cc && chmod 777 /home/9cc

# Copy team context and Claude plugins/skills from the build context.
# These are copied at build time, not mounted at runtime, so host paths stay hidden.
# COPY claude comes before claude-local so the explicit local copy wins.
COPY claude /home/9cc/.claude
COPY investtal /home/9cc/.investtal
COPY proto /home/9cc/.proto
COPY prototools /home/9cc/.prototools

# Claude CLI source: host copy (Linux ELF / shebang) or npm install (macOS/Windows hosts).
# claude-source.mode is "host" or "npm" (written by stage_claude_local).
COPY claude-local /home/9cc/.claude/local
COPY claude-source.mode /tmp/claude-source.mode
RUN mode="$(tr -d '[:space:]' < /tmp/claude-source.mode)" \
    && if [ "$mode" = "npm" ]; then \
         npm install -g @anthropic-ai/claude-code \
         && mkdir -p /home/9cc/.claude/local/bin \
         && ln -sfn "$(command -v claude)" /home/9cc/.claude/local/bin/claude; \
       elif [ ! -e /home/9cc/.claude/local/bin/claude ] && [ -f /home/9cc/.claude/local/claude ]; then \
         mkdir -p /home/9cc/.claude/local/bin \
         && ln -sfn /home/9cc/.claude/local/claude /home/9cc/.claude/local/bin/claude; \
       fi \
    && rm -f /tmp/claude-source.mode \
    && if [ ! -e /home/9cc/.claude/local/bin/claude ]; then \
         echo "9cc sandbox image: claude missing under /home/9cc/.claude/local/bin" >&2; \
         exit 1; \
       fi

# Copy zsh config if the host provided it; otherwise create minimal files.
COPY zshrc /home/9cc/.zshrc
COPY zshenv /home/9cc/.zshenv

# Copy the logging proxy and container entrypoint.
COPY agent-proxy.mjs /home/9cc/agent-proxy.mjs
COPY sandbox-entrypoint.sh /home/9cc/sandbox-entrypoint.sh
RUN chmod -R 777 /home/9cc && chmod 755 /home/9cc/sandbox-entrypoint.sh

ENV HOME=/home/9cc
ENV SHELL=/usr/bin/zsh
# Prefer image-local Claude, then npm global, then anything else on PATH.
ENV PATH="/home/9cc/.claude/local/bin:/usr/local/bin:${PATH}"

WORKDIR /workspace
ENTRYPOINT ["/home/9cc/sandbox-entrypoint.sh"]
CMD ["claude"]
