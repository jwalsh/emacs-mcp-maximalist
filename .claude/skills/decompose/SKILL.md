---
name: decompose
description: Launch parallel agents for conjecture research and build step implementation. Use after bootstrap is verified and build steps are ready.
user-invocable: true
allowed-tools: Read, Bash, Grep, Glob, Agent
context: fork
---

# Parallel Agent Decomposition

## Sentinel

Before launching agents, check what work already exists:

```bash
# Check for existing research docs
for i in $(seq -w 1 8); do
  test -f "docs/conjectures/c-0${i}-research.md" && echo "EXISTS: C-00${i}" || echo "MISSING: C-00${i}"
done

# Check for existing design docs
ls docs/design/*.md 2>/dev/null && echo "DESIGN_DOCS: found" || echo "DESIGN_DOCS: none"

# Check build step completion
test -f src/emcp-stdio.el && echo "emcp-stdio.el: exists" || echo "emcp-stdio.el: missing"
test -f src/introspect.el && echo "introspect.el: exists" || echo "introspect.el: missing"
test -f tests/test-emcp-stdio.el && echo "test-emcp-stdio.el: exists" || echo "test-emcp-stdio.el: missing"
```

- Skip launching research agents for conjectures that already have
  `docs/conjectures/c-NNN-research.md`.
- Skip launching implementation agents for build steps whose source
  files exist AND whose acceptance tests pass.
- Skip launching design agents for steps that already have
  `docs/design/<component>.md`.
- If everything exists and passes: report "all work complete, nothing
  to decompose." Stop.
- Report which agents will be launched and which were skipped.

Read CLAUDE.md and spec.org to identify parallelizable work.

## Research Agents (one per open conjecture)

For each conjecture (C-001 through C-008):
- Launch a background Agent with subagent_type=general-purpose
- Prompt: research the conjecture, produce findings with measurement
  approach, confound analysis, and experiment design
- Output to: `docs/conjectures/c-NNN-research.md`

## Implementation Agents (for unblocked build steps)

For the current unblocked build step:
- Launch a background Agent with isolation=worktree
- Prompt: implement the component, write tests, meet acceptance criteria
  from CLAUDE.md's build order
- On completion: review changes, run tests, merge if passing

## Design Agents (for blocked steps)

For steps that are blocked but need design work:
- Launch a background Agent with subagent_type=general-purpose
- Prompt: produce a design document covering interfaces, edge cases,
  and integration points with completed layers
- Output to: `docs/design/<component>.md`

## Integration Protocol

As agents complete:
1. **Research** -> commit to docs/, update conjecture status
2. **Implementation** -> merge from worktree, run full test suite
3. **Design** -> commit to docs/, review before implementation begins

## Warning

Per MAST taxonomy (arXiv 2503.13657): value is in isolation and
determinism, not raw throughput. Each agent gets its own worktree
or output directory. No shared mutable state between agents.
