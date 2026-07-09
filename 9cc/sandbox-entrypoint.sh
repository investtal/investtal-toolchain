#!/usr/bin/env bash
# Container entrypoint: start agent-proxy, then run claude through it.
set -euo pipefail

: "${AGENT_PROXY_PORT:=8787}"
: "${ANTHROPIC_BASE_URL:=https://api.anthropic.com}"
: "${AGENT_PROXY_LOG_DIR:=/tmp/9cc-egress}"

mkdir -p "$AGENT_PROXY_LOG_DIR"

# Start proxy in background, forwarding to the real upstream.
UPSTREAM_URL="$ANTHROPIC_BASE_URL" PORT="$AGENT_PROXY_PORT" LOG_DIR="$AGENT_PROXY_LOG_DIR" \
    node /home/9cc/agent-proxy.mjs &
PROXY_PID=$!

# Wait for proxy to listen.
for _ in $(seq 1 30); do
    if curl -fsS "http://localhost:$AGENT_PROXY_PORT/healthz" >/dev/null 2>&1; then break; fi
    sleep 0.1
done

# Point Claude at the proxy, leaving the rest of the env allowlist to the launcher.
export ANTHROPIC_BASE_URL="http://localhost:$AGENT_PROXY_PORT"
export PATH="/home/9cc/.claude/local/bin:$PATH"

cleanup() { kill "$PROXY_PID" 2>/dev/null || true; }
trap cleanup EXIT

exec claude "$@"
