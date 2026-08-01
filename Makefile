.PHONY: help prepare lint format build test run release

# pre-commit runs through `uvx`, not through a project venv. This repo has no
# Python package of its own: there is no pyproject.toml and nothing to
# `uv sync`, so a version-pinned ephemeral tool run is the whole dependency
# story. uv caches the environment after the first invocation, and every linter
# behind pre-commit is pinned in .pre-commit-config.yaml.
PRE_COMMIT := uvx pre-commit@4.4.0

# The SwiftPM package lands via the menu-bar-mvp branch. Until it merges,
# `build` and `test` skip gracefully (exit 0) — mirroring ci.yml's
# Package.swift probe — so the "make lint and make test must pass" rule in
# CLAUDE.md holds on tooling-only branches too. Targets that are meaningless
# without a package (format, run, release) instead fail fast with a clear
# message rather than a cryptic SwiftPM "no manifest" error.
CHECK_PACKAGE = @test -f Package.swift || \
  { echo "error: Package.swift not found — the app scaffolding lands via the menu-bar-mvp branch"; exit 1; }
SKIP_NO_PACKAGE = echo "skipped: Package.swift not present (lands via the menu-bar-mvp branch)"

# `help` is the first non-`.PHONY` target, so bare `make` prints the table.
# The awk one-liner scans every target line of the form `<name>: ... ## <desc>`
# and renders it. Annotate every new target with `## <one-line description>` to
# make it self-documenting.
help: ## Show available commands
	@echo ""
	@echo "Available commands:"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Run 'make prepare' once per clone, and 'make lint' before committing."
	@echo ""

prepare: ## Install the git hooks (pre-commit + commit-msg)
	$(PRE_COMMIT) install --install-hooks

lint: ## Run every pre-commit hook over the whole tree
	$(PRE_COMMIT) run --all-files

format: ## Rewrite Swift sources (swift-format, then swiftlint autocorrect)
	$(CHECK_PACKAGE)
	@command -v swift >/dev/null || \
	  { echo "error: swift not found — install Xcode or the Command Line Tools"; exit 1; }
	swift format format --in-place --recursive Sources
	@if command -v swiftlint >/dev/null; then \
	  scripts/swiftlint.sh --fix --quiet; \
	else \
	  echo "note: swiftlint not found (run 'mise install') — autocorrect skipped"; \
	fi

build: ## Build the app (debug; skips until Package.swift lands)
	@if test -f Package.swift; then swift build; else $(SKIP_NO_PACKAGE); fi

test: ## Run the test suite (skips until Package.swift lands)
	@if test -f Package.swift; then swift test; else $(SKIP_NO_PACKAGE); fi

run: ## Build and launch the menu bar app
	$(CHECK_PACKAGE)
	swift run

release: ## Build the app (release configuration)
	$(CHECK_PACKAGE)
	swift build -c release
