SHELL := /bin/bash
.DEFAULT_GOAL := work

SENTINEL := .sentinels
CLAUDE   := claude --dangerously-skip-permissions -p

# Parallelism: phases 5-6, 7, 8 are independent.
# gmake -j3 decompose exploits this.  gmake -j1 is safe but sequential.
MAKEFLAGS += --output-sync=target

# --- git notes convention (adopted from aq project) -----------------------
# Applied to each commit via: gmake note SHA=<sha> ROLE=<role> TESTING=<...>
# Or automatically by the note-last helper after each sentinel touch.
#
# Format:
#   X-Agent-Role: builder|reviewer|bootstrap|researcher
#   X-Agent-Runner: Claude Code 2.1.78
#   X-Agent-Model: Opus 4.6
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
  echo "X-Phase: $(2)"; \
  echo "X-Testing: $(3)"; \
  echo "X-Invariants: $(4)"; \
  echo "X-Deviations: $(5)"; \
)" $(if $(6),$(6),HEAD)
endef

# --- sentinel directory ---------------------------------------------------

$(SENTINEL):
	@mkdir -p $@

# --- phase 1: bootstrap ---------------------------------------------------

$(SENTINEL)/bootstrap: spec.org | $(SENTINEL)
	$(CLAUDE) "/bootstrap"
	@touch $@

# --- phase 2-3: generate CLAUDE.md ----------------------------------------

$(SENTINEL)/generate-claude-md: spec.org $(SENTINEL)/bootstrap | $(SENTINEL)
	$(CLAUDE) "/generate-claude-md"
	@test -f CLAUDE.md  # post-condition: CLAUDE.md must exist
	@touch $@

# --- phase 4: review prompt -----------------------------------------------

$(SENTINEL)/review-prompt: $(SENTINEL)/generate-claude-md | $(SENTINEL)
	$(CLAUDE) "/review-prompt"
	@test -f docs/meta-prompt-v0-review.md  # post-condition
	@touch $@

# --- phase 5-6: wire backlog (parallel with 7, 8) -------------------------

$(SENTINEL)/wire-backlog: $(SENTINEL)/review-prompt | $(SENTINEL)
	$(CLAUDE) "/wire-backlog"
	@touch $@

# --- phase 7: setup memory (parallel with 5-6, 8) -------------------------

$(SENTINEL)/setup-memory: $(SENTINEL)/review-prompt | $(SENTINEL)
	$(CLAUDE) "/setup-memory"
	@touch $@

# --- phase 8: health check (parallel with 5-6, 7) -------------------------

$(SENTINEL)/health-check: $(SENTINEL)/review-prompt | $(SENTINEL)
	$(CLAUDE) "/health-check"
	@test -f bin/health-check.sh  # post-condition
	@touch $@

# --- phase 9-10: verify bootstrap -----------------------------------------

$(SENTINEL)/verify-bootstrap: $(SENTINEL)/wire-backlog $(SENTINEL)/setup-memory $(SENTINEL)/health-check | $(SENTINEL)
	$(CLAUDE) "/verify-bootstrap"
	@touch $@

# --- phase 11: decompose --------------------------------------------------

$(SENTINEL)/decompose: $(SENTINEL)/verify-bootstrap | $(SENTINEL)
	$(CLAUDE) "/decompose"
	@touch $@

# --- phase 12: work (implementation, follows build order) -----------------
# Runs the actual build order from CLAUDE.md: escape → introspect →
# dispatch → server-core → server-max → health-check validation.

$(SENTINEL)/work: $(SENTINEL)/decompose | $(SENTINEL)
	$(CLAUDE) "Implement the build order from CLAUDE.md. Follow steps 1-6 sequentially. For each step: write the code, write tests, run the acceptance test. Stop on failure. Commit each passing step separately using conventional commits and --trailer 'Co-authored-by: Claude Opus 4.6 (1M context) <noreply@anthropic.com>'. After each commit, add a git note with this format: X-Agent-Role: builder / X-Agent-Runner: $(AGENT_RUNNER) / X-Agent-Model: $(AGENT_MODEL) / X-Phase: build-step-N / X-Testing: <acceptance test, pass or fail> / X-Invariants: manifest-format-invariant (see CLAUDE.md) / X-Deviations: none."
	@touch $@

# --- convenience aliases (phony → real sentinel) ---------------------------

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
        clean status graph parallel note

# --- parallel: run the three independent post-review phases concurrently --

parallel:
	@$(MAKE) -j3 wire-backlog setup-memory health-check

# --- note: manually annotate a commit ------------------------------------

note:
ifndef SHA
	$(error usage: gmake note SHA=<sha> ROLE=builder TESTING="tests pass")
endif
	$(call git-note,$(or $(ROLE),builder),manual,$(or $(TESTING),n/a),$(or $(INVARIANTS),n/a),$(or $(DEVIATIONS),none),$(SHA))

# --- force re-run a single phase ------------------------------------------

force-%:
	@rm -f $(SENTINEL)/$*
	@$(MAKE) $*

# --- resume from wherever we left off -------------------------------------

resume:
	@$(MAKE) work

.PHONY: resume

# --- status ----------------------------------------------------------------

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

# --- dependency graph (for debugging) -------------------------------------

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

# --- clean -----------------------------------------------------------------

clean:
	rm -rf $(SENTINEL)
