SHELL := /bin/bash
.DEFAULT_GOAL := work

SENTINEL     := .sentinels
CLAUDE       := claude --dangerously-skip-permissions -p
EMACSCLIENT  := emacsclient
MANIFEST      := functions-compact.jsonl
MANIFEST_CORE := functions-core.jsonl
MANIFEST_FULL := emacs-functions.json

# Parallelism: phases 5-6, 7, 8 are independent.
# gmake -j3 decompose exploits this.  gmake -j1 is safe but sequential.
MAKEFLAGS += --output-sync=target

# --- git notes convention (adopted from aq project) -----------------------
#
# Format (co-author attribution lives here, not in commit trailers):
#   X-Agent-Role: builder|reviewer|bootstrap|researcher
#   X-Agent-Runner: Claude Code 2.1.78
#   X-Agent-Model: Opus 4.6
#   X-Co-Author: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
#   X-Phase: <makefile phase name>
#   X-Conjectures: <IDs if relevant>
#   X-Testing: <what was tested, pass/fail>
#   X-Invariants: <contracts preserved or violated>
#   X-Deviations: <deviation from plan/spec, or "none">

AGENT_RUNNER  := Claude Code 2.1.78
AGENT_MODEL   := Opus 4.6

define git-note
git notes add --force -m "$$( \
  echo "X-Agent-Role: $(1)"; \
  echo "X-Agent-Runner: $(AGENT_RUNNER)"; \
  echo "X-Agent-Model: $(AGENT_MODEL)"; \
  echo "X-Co-Author: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"; \
  echo "X-Phase: $(2)"; \
  echo "X-Testing: $(3)"; \
  echo "X-Invariants: $(4)"; \
  echo "X-Deviations: $(5)"; \
)" $(if $(6),$(6),HEAD)
endef

# =========================================================================
#  BOOTSTRAP PIPELINE (sentinel-gated, claude -p invocations)
# =========================================================================

$(SENTINEL):
	@mkdir -p $@

$(SENTINEL)/bootstrap: spec.org | $(SENTINEL)
	$(CLAUDE) "/bootstrap"
	@touch $@

$(SENTINEL)/generate-claude-md: spec.org $(SENTINEL)/bootstrap | $(SENTINEL)
	$(CLAUDE) "/generate-claude-md"
	@test -f CLAUDE.md
	@touch $@

$(SENTINEL)/review-prompt: $(SENTINEL)/generate-claude-md | $(SENTINEL)
	$(CLAUDE) "/review-prompt"
	@test -f docs/meta-prompt-v0-review.md
	@touch $@

$(SENTINEL)/wire-backlog: $(SENTINEL)/review-prompt | $(SENTINEL)
	$(CLAUDE) "/wire-backlog"
	@touch $@

$(SENTINEL)/setup-memory: $(SENTINEL)/review-prompt | $(SENTINEL)
	$(CLAUDE) "/setup-memory"
	@touch $@

$(SENTINEL)/health-check: $(SENTINEL)/review-prompt | $(SENTINEL)
	$(CLAUDE) "/health-check"
	@test -f bin/health-check.sh
	@touch $@

$(SENTINEL)/verify-bootstrap: $(SENTINEL)/wire-backlog $(SENTINEL)/setup-memory $(SENTINEL)/health-check | $(SENTINEL)
	$(CLAUDE) "/verify-bootstrap"
	@touch $@

$(SENTINEL)/decompose: $(SENTINEL)/verify-bootstrap | $(SENTINEL)
	$(CLAUDE) "/decompose"
	@touch $@

$(SENTINEL)/work: $(SENTINEL)/decompose | $(SENTINEL)
	$(CLAUDE) "Implement the build order from CLAUDE.md. Follow steps 1-6 sequentially. Write code, write tests, run acceptance tests. Stop on failure. Stacked commits with conventional prefixes. Co-author attribution in git notes only (X-Co-Author field), not in commit message."
	@touch $@

# =========================================================================
#  BUILD TARGETS (actual project build, not pipeline)
# =========================================================================

# --- manifest generation --------------------------------------------------

$(MANIFEST_FULL): src/introspect.el
	$(EMACSCLIENT) --eval '(load-file "src/introspect.el")'
	$(EMACSCLIENT) --eval '(emcp-write-manifest "$(MANIFEST_FULL)")'

$(MANIFEST): src/introspect.el
	$(EMACSCLIENT) --eval '(load-file "src/introspect.el")'
	$(EMACSCLIENT) --eval '(emcp-write-manifest-compact "$(MANIFEST)")'

$(MANIFEST_CORE): src/introspect.el
	$(EMACSCLIENT) --eval '(load-file "src/introspect.el")'
	$(EMACSCLIENT) --eval '(emcp-write-manifest-core "$(MANIFEST_CORE)")'

manifest: $(MANIFEST) $(MANIFEST_CORE)
	@echo "Manifest (max): $$(wc -l < $(MANIFEST)) functions"
	@echo "Manifest (core): $$(wc -l < $(MANIFEST_CORE)) functions"

# --- test -----------------------------------------------------------------

test:
	emacs --batch -Q -l src/emcp-stdio.el \
		-l tests/test-emcp-stdio.el \
		-l tests/test_io_layer.el \
		-l tests/test_sexp_construction.el \
		-l tests/test-integration.el \
		-f ert-run-tests-batch-and-exit

test-e2e:
	emacs --batch -Q -l src/emcp-stdio.el \
		-l tests/test-e2e.el \
		-f ert-run-tests-batch-and-exit

test-all: test test-e2e

# --- server ---------------------------------------------------------------

run: run-core

run-core:
	emacs --batch -Q -l src/emcp-stdio.el -f emcp-stdio-start

run-max:
	emacs --batch -l src/emcp-stdio.el -f emcp-stdio-start

# --- lint -----------------------------------------------------------------

lint-org:
	emacs --batch -Q -l lisp/org-lint-batch.el -f emcp-org-lint-batch

lint: lint-org

# --- health ---------------------------------------------------------------

health:
	@bash bin/health-check.sh

# --- docs -----------------------------------------------------------------

README.md: README.org lisp/publish.el
	$(EMACSCLIENT) -l lisp/publish.el --eval '(emcp-publish-readme)'

sync: README.md

# --- toolchain init -------------------------------------------------------

init-bd:
	@bd init 2>/dev/null || echo "bd already initialized"

init-cprr:
	@cprr init 2>/dev/null || echo "cprr already initialized"

init-sb:
	@sb init 2>/dev/null || echo "sb already initialized"

init-aq:
	@aq init 2>/dev/null || echo "aq already initialized"

init-tools: init-bd init-cprr init-sb init-aq
	@echo "toolchain initialized (bd, cprr, sb, aq)"

# =========================================================================
#  CONVENIENCE / META
# =========================================================================

bootstrap:         $(SENTINEL)/bootstrap
generate-claude-md: $(SENTINEL)/generate-claude-md
review-prompt:     $(SENTINEL)/review-prompt
wire-backlog:      $(SENTINEL)/wire-backlog
setup-memory:      $(SENTINEL)/setup-memory
health-check:      $(SENTINEL)/health-check
verify-bootstrap:  $(SENTINEL)/verify-bootstrap
decompose:         $(SENTINEL)/decompose
work:              $(SENTINEL)/work

.PHONY: bootstrap generate-claude-md review-prompt wire-backlog \
        setup-memory health-check verify-bootstrap decompose work \
        clean status graph parallel note test test-e2e test-all health \
        run run-core run-max lint lint-org \
        manifest sync init-bd init-cprr init-sb init-aq init-tools resume

parallel:
	@$(MAKE) -j3 wire-backlog setup-memory health-check

note:
ifndef SHA
	$(error usage: gmake note SHA=<sha> ROLE=builder TESTING="tests pass")
endif
	$(call git-note,$(or $(ROLE),builder),manual,$(or $(TESTING),n/a),$(or $(INVARIANTS),n/a),$(or $(DEVIATIONS),none),$(SHA))

force-%:
	@rm -f $(SENTINEL)/$*
	@$(MAKE) $*

resume:
	@$(MAKE) work

status:
	@echo "=== pipeline status ==="
	@for phase in bootstrap generate-claude-md review-prompt \
	              wire-backlog setup-memory health-check \
	              verify-bootstrap decompose work; do \
	  if [ -f $(SENTINEL)/$$phase ]; then \
	    echo "  ✓ $$phase  ($$(stat -f '%Sm' -t '%Y-%m-%d %H:%M' $(SENTINEL)/$$phase))"; \
	  else \
	    echo "  · $$phase"; \
	  fi; \
	done
	@echo "=== build artifacts ==="
	@test -f $(MANIFEST) && echo "  ✓ $(MANIFEST)  ($$(wc -l < $(MANIFEST)) lines)" || echo "  · $(MANIFEST)"
	@test -f $(MANIFEST_FULL) && echo "  ✓ $(MANIFEST_FULL)" || echo "  · $(MANIFEST_FULL)"
	@test -f README.md && echo "  ✓ README.md" || echo "  · README.md"

graph:
	@echo "spec.org"
	@echo "  → bootstrap"
	@echo "    → generate-claude-md"
	@echo "      → review-prompt"
	@echo "        ├→ wire-backlog ──────┐"
	@echo "        ├→ setup-memory ──────┤  (gmake -j3 parallel)"
	@echo "        └→ health-check ──────┤"
	@echo "                              ↓"
	@echo "                    verify-bootstrap"
	@echo "                              ↓"
	@echo "                          decompose"
	@echo "                              ↓"
	@echo "                            work"
	@echo ""
	@echo "  manifest → {run-core, run-max}"
	@echo "  README.org → README.md (sync)"

clean:
	rm -rf $(SENTINEL)

clean-build:
	rm -f $(MANIFEST) $(MANIFEST_CORE) $(MANIFEST_FULL)

clean-all: clean clean-build
