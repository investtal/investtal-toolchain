# Shared `make bootstrap` for Investtal repos.
#
# Runs: proto install (if .prototools), git config core.hooksPath .githooks,
# pnpm install (if package.json), then install-semgrep (if uv is present).
# Idempotent. Guards make .githooks steps on file existence so the same Makefile
# works for node, JVM, and docs repos.

# semgrep is installed from the investtal-toolchain hash-locked lockfile (every
# artifact pinned with --require-hashes) into a repo-local venv, so the version
# matches CI exactly and scripts/security-gate.sh runs the same binary as Jenkins.
SEMGREP_VENV := .semgrep-venv
SEMGREP_REQUIREMENTS_URL ?= https://raw.githubusercontent.com/investtal/investtal-toolchain/main/semgrep/requirements.txt

.PHONY: bootstrap install-hooks install-semgrep

bootstrap:
	@if [ -f .prototools ]; then \
		echo "==> proto install"; \
		proto install; \
	fi
	@if [ -d .githooks ]; then \
		echo "==> git config core.hooksPath .githooks"; \
		git config core.hooksPath .githooks; \
		chmod +x .githooks/* 2>/dev/null || true; \
	fi
	@if [ -f package.json ]; then \
		echo "==> pnpm install"; \
		pnpm install; \
	fi
	@$(MAKE) --no-print-directory install-semgrep
	@echo "==> bootstrap complete"

# Install the pinned, hash-locked semgrep CLI into $(SEMGREP_VENV) via uv.
# Idempotent: skips when the venv already has a working semgrep. Soft-fails
# (never blocks bootstrap) when uv is missing — security-gate degrades gracefully.
install-semgrep:
	@if ! command -v uv >/dev/null 2>&1; then \
		echo "==> install-semgrep: uv not found — skipping (install uv: https://docs.astral.sh/uv/)"; \
	elif [ -x "$(SEMGREP_VENV)/bin/semgrep" ] && "$(SEMGREP_VENV)/bin/semgrep" --version >/dev/null 2>&1; then \
		echo "==> install-semgrep: $(SEMGREP_VENV) present ($$($(SEMGREP_VENV)/bin/semgrep --version)) — skipping"; \
	else \
		echo "==> install-semgrep: uv venv + hash-locked install from toolchain"; \
		uv venv --python 3.12 "$(SEMGREP_VENV)" && \
		VIRTUAL_ENV="$(CURDIR)/$(SEMGREP_VENV)" uv pip install --require-hashes -r "$(SEMGREP_REQUIREMENTS_URL)" && \
		echo "==> install-semgrep: installed $$($(SEMGREP_VENV)/bin/semgrep --version)"; \
	fi

install-hooks:
	@if [ -d .githooks ]; then \
		git config core.hooksPath .githooks; \
		chmod +x .githooks/* 2>/dev/null || true; \
		echo "Git hooks installed (core.hooksPath = .githooks)."; \
	else \
		echo "No .githooks/ directory found." >&2; exit 1; \
	fi
