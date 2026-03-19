# Makefile Review: emacs-mcp-maximalist

**Date**: 2026-03-19
**Reviewer**: Claude Opus 4.6 (automated)
**File**: `/Makefile` (279 lines)
**Overall Grade**: **B**

The Makefile is well-structured for a project that evolved from Python to pure Elisp. Sentinel-gated bootstrap pipeline is a good pattern. Several issues need attention, the most critical being missing `.PHONY` entries and test coverage gaps.

---

## Critical Issues

### C1. `clean-build` and `clean-all` missing from `.PHONY`

These are phony targets but are not declared. If a file named `clean-build` or `clean-all` is ever created, the targets silently become no-ops.

**Current** (line 214-220):
```makefile
.PHONY: bootstrap generate-claude-md review-prompt wire-backlog \
        setup-memory health-check verify-bootstrap decompose work \
        clean status graph parallel note test test-e2e test-all coverage health \
        run run-core run-max inspect \
        daemon-start daemon-stop daemon-restart daemon-status \
        lint lint-org \
        manifest sync init-bd init-cprr init-sb init-aq init-tools resume
```

**Fix** -- add `clean-build clean-all`:
```makefile
.PHONY: bootstrap generate-claude-md review-prompt wire-backlog \
        setup-memory health-check verify-bootstrap decompose work \
        clean clean-build clean-all \
        status graph parallel note test test-e2e test-all coverage health \
        run run-core run-max inspect \
        daemon-start daemon-stop daemon-restart daemon-status \
        lint lint-org \
        manifest sync init-bd init-cprr init-sb init-aq init-tools resume
```

### C2. `test` target omits two test files

The `test` target loads 4 test files but the `tests/` directory contains 7 (excluding `test-coverage.el` which has its own entry point):

| File | Loaded in `test`? | Notes |
|------|-------------------|-------|
| `test-emcp-stdio.el` | Yes | |
| `test_io_layer.el` | Yes | |
| `test_sexp_construction.el` | Yes | |
| `test-integration.el` | Yes | |
| `test-e2e.el` | No | Has own target `test-e2e` -- correct |
| `test-coverage.el` | No | Has own target `coverage` -- correct |
| `test-daemon-lifecycle.el` | No | **Missing** -- no target at all |
| `test-tier1-smoke.el` | No | **Missing** -- no target at all |
| `test-org-lint.sh` | No | Shell script, not ERT -- separate concern |

`test-daemon-lifecycle.el` and `test-tier1-smoke.el` are unreachable from the Makefile. Neither is in `test`, `test-e2e`, `test-all`, or `coverage`. They can only be run by typing the full `emacs --batch ...` invocation by hand.

**Fix** -- add targets:
```makefile
test-daemon:
	emacs --batch -Q -l src/emcp-stdio.el \
		-l tests/test-daemon-lifecycle.el \
		-f ert-run-tests-batch-and-exit

test-smoke:
	emacs --batch -Q -l src/emcp-stdio.el \
		-l tests/test-tier1-smoke.el \
		-f ert-run-tests-batch-and-exit

test-all: test test-e2e test-smoke
```

Note: `test-daemon` is excluded from `test-all` deliberately because it requires a live daemon. Add `.PHONY: test-daemon test-smoke` as well.

### C3. Manifest targets have race condition under `make -j`

The `manifest` target depends on `$(MANIFEST)` and `$(MANIFEST_CORE)`. Both of these targets independently run `emacsclient --eval '(load-file "src/introspect.el")'` as their first recipe line. Under `make -j2`, both fire simultaneously and two `load-file` calls hit the daemon at once. This is usually safe but violates the principle of least surprise and wastes a round trip.

**Fix** -- make `$(MANIFEST_CORE)` depend on `$(MANIFEST)` (so `load-file` runs once), or extract a sentinel for the `load-file` step:
```makefile
$(SENTINEL)/introspect-loaded: src/introspect.el | $(SENTINEL)
	$(EMACSCLIENT) --eval '(load-file "src/introspect.el")'
	@touch $@

$(MANIFEST_FULL): $(SENTINEL)/introspect-loaded
	$(EMACSCLIENT) --eval '(emcp-write-manifest "$(MANIFEST_FULL)")'

$(MANIFEST): $(SENTINEL)/introspect-loaded
	$(EMACSCLIENT) --eval '(emcp-write-manifest-compact "$(MANIFEST)")'

$(MANIFEST_CORE): $(SENTINEL)/introspect-loaded
	$(EMACSCLIENT) --eval '(emcp-write-manifest-core "$(MANIFEST_CORE)")'
```

---

## Moderate Issues

### M1. `README.md` target requires a running daemon but has no guard

The `README.md` target uses `$(EMACSCLIENT)` to call `emcp-publish-readme`, which requires a running Emacs daemon. Unlike `run-core`/`run-max` (which use `emacs --batch`), this target will silently fail with "emacsclient: can't find socket" if no daemon is running. There is no prerequisite that checks or starts the daemon.

**Fix** -- either add a daemon check or convert to batch mode:
```makefile
README.md: README.org lisp/publish.el
	emacs --batch -Q -l ox-md -l lisp/publish.el \
		--eval '(emcp-publish-readme)'
```

### M2. `daemon-restart` has a fixed `sleep 1` that may not be enough

The `daemon-restart` target does `daemon-stop`, `sleep 1`, then `daemon-start`. The `sleep 1` is a race condition: on slow systems or under load, the socket file may not be cleaned up in 1 second. The project's own chaos test report documented daemon instability under concurrent load.

**Fix** -- poll for socket disappearance:
```makefile
daemon-restart: daemon-stop
	@for i in 1 2 3 4 5; do \
	  emacsclient --eval '(emacs-pid)' 2>/dev/null || break; \
	  sleep 1; \
	done
	@$(MAKE) daemon-start
```

### M3. `status` target uses macOS-specific `stat -f` flag

Line 244: `stat -f '%Sm' -t '%Y-%m-%d %H:%M'` is macOS (BSD) syntax. On Linux, this is `stat --format='%y'`. The Makefile sets `SHELL := /bin/bash` but does not guard for OS.

**Fix** -- use a portable approach:
```makefile
# At the top
DATE_CMD := $(if $(shell stat --version 2>/dev/null),stat --format='%.19y',stat -f '%Sm' -t '%Y-%m-%d %H:%M')
```

Or accept macOS-only and document it.

### M4. `inspect` package name is correct but may go stale

The Makefile uses `@modelcontextprotocol/inspector`, which is the current (verified: v0.21.1) package name. The older `@anthropic-ai/mcp-inspector` package does not exist on npm. This is correct today but worth noting as a dependency that could change.

### M5. `lint-org` missing from `test-all`

The `lint-org` target is a useful CI check but is not wired into `test-all`. Org lint errors (broken links, missing titles, unmatched src blocks) would go undetected in a `make test-all` run.

**Fix**:
```makefile
test-all: test test-e2e lint-org
```

### M6. Stale `__pycache__` in `src/` not cleaned by any target

`src/__pycache__/` contains `.pyc` files from deleted Python sources (`escape.py`, `dispatch.py`, `server.py`). The `clean-build` target does not remove it. While `.gitignore` excludes it, the stale artifact is confusing.

**Fix** -- add to `clean-build`:
```makefile
clean-build:
	rm -f $(MANIFEST) $(MANIFEST_CORE) $(MANIFEST_FULL)
	rm -rf src/__pycache__
```

---

## Minor Issues

### m1. No `help` target

GNU Make convention is to provide a `help` or default target that lists available targets. The `.DEFAULT_GOAL` is `work`, which triggers the full sentinel pipeline. A new user running bare `make` will invoke `claude --dangerously-skip-permissions -p`, which is surprising.

**Fix**:
```makefile
help:
	@echo "Primary targets:"
	@echo "  test         Run unit tests (ERT)"
	@echo "  test-all     Run all tests"
	@echo "  run-core     Start MCP server (core, ~50 tools)"
	@echo "  run-max      Start MCP server (maximalist)"
	@echo "  manifest     Generate function manifests (requires daemon)"
	@echo "  lint         Lint org files"
	@echo "  health       Run health check"
	@echo "  coverage     Run tests with coverage"
	@echo "  status       Show pipeline status"
	@echo ""
	@echo "Daemon targets:"
	@echo "  daemon-start daemon-stop daemon-restart daemon-status"
	@echo ""
	@echo "Bootstrap pipeline (requires claude CLI):"
	@echo "  work         Full bootstrap + implementation"
	@echo "  clean        Remove sentinel files"
	@echo "  clean-all    Remove sentinels + build artifacts"
```

### m2. `test-org-lint.sh` has no Makefile target

`tests/test-org-lint.sh` exists but is not invoked by any target. It appears to be a predecessor to `lint-org`.

### m3. `note` target error message says `gmake` not `make`

Line 227: `$(error usage: gmake note SHA=<sha> ...)` hardcodes `gmake`. On Linux, users type `make`. Minor cosmetic issue.

### m4. Manifest file targets don't use `$(CURDIR)` for paths

The `inspect` target correctly uses `$(CURDIR)/src/emcp-stdio.el` for the absolute path, but the manifest targets pass bare `$(MANIFEST_FULL)` and `$(MANIFEST)` to `emacsclient --eval`. Since `emacsclient` inherits the working directory, this works -- but if the eval changes the Emacs daemon's `default-directory`, the relative path could resolve incorrectly.

**Suggestion**: Use `$(CURDIR)/$(MANIFEST)` in the emacsclient eval calls for robustness.

### m5. `MAKEFLAGS += --output-sync=target` may not be portable

The `--output-sync` flag requires GNU Make >= 4.0. BSD make (which ships on macOS) does not support it. Since the project uses `gmake` (GNU Make via Homebrew), this is fine in practice but should be documented.

### m6. `run-max` loads user init but `run-core` does not

`run-core` uses `-Q` (no init), `run-max` omits it (loads user init). This is documented and intentional per CLAUDE.md. However, it means `run-max` behavior is non-reproducible across machines. This is by design (maximalist mode exposes user-configured functions) but worth a comment in the Makefile.

---

## What Works Well

1. **Sentinel pattern**: The `.sentinels/` directory with touch files is a clean way to gate idempotent pipeline phases. Running a phase twice correctly skips it.

2. **Separation of build vs. bootstrap**: The `BUILD TARGETS` section (manifest, test, run) is cleanly separated from the `BOOTSTRAP PIPELINE` section (sentinel-gated claude invocations).

3. **`force-%` pattern rule**: `force-work` etc. correctly removes the sentinel then re-runs -- a useful escape hatch.

4. **`graph` target**: Nice visualization of the dependency tree. Matches the actual sentinel DAG.

5. **`status` target**: Pragmatic introspection of pipeline state with timestamps.

6. **Core vs. maximalist mode selection**: The `-Q` flag difference between `run-core` and `run-max` is minimal and correct.

7. **No Python references**: The Makefile has fully transitioned to pure Elisp. No stale Python targets remain (the `__pycache__` is only in the filesystem, not referenced).

---

## Revised `.PHONY` Block

```makefile
.PHONY: bootstrap generate-claude-md review-prompt wire-backlog \
        setup-memory health-check verify-bootstrap decompose work \
        clean clean-build clean-all \
        status graph parallel note \
        test test-e2e test-all test-daemon test-smoke coverage \
        health \
        run run-core run-max inspect \
        daemon-start daemon-stop daemon-restart daemon-status \
        lint lint-org \
        manifest sync \
        init-bd init-cprr init-sb init-aq init-tools \
        resume help
```

---

## Summary

| Severity | Count | Issues |
|----------|-------|--------|
| Critical | 3 | Missing `.PHONY` entries; 2 test files unreachable; manifest `-j` race |
| Moderate | 6 | README.md daemon dependency; daemon-restart race; macOS-only stat; inspector package; lint not in test-all; stale pycache |
| Minor | 6 | No help target; orphan test script; gmake hardcoded; relative paths in eval; MAKEFLAGS portability; run-max comment |

The Makefile is functional and well-organized for its primary author. The critical issues are low-effort fixes. The project would benefit most from (1) completing the `.PHONY` block, (2) wiring in the missing test targets, and (3) adding a `help` target so the default goal is not the full bootstrap pipeline.
