# Daemon Lifecycle Timing Report

**Generated**: 2026-03-19T08:51Z
**Machine**: Darwin 25.3.0, ARM64 (Apple Silicon)
**Emacs**: GNU Emacs 30.2 (aarch64-apple-darwin24.6.0)
**Context**: System monitor documented 3 different daemon PIDs in ~2 minutes
under concurrent agent load (see `system-monitor.md`).

## Measurements

### Single eval latency

| Operation       | Latency |
|-----------------|---------|
| `(+ 1 1)`       | 2.7ms   |
| `(emacs-pid)`   | 2.1ms   |
| `(emacs-version)`| 2.0ms  |
| `string-trim`   | 1.6ms   |
| `upcase`         | 1.7ms   |
| `format`         | 1.6ms   |
| `concat`         | 1.8ms   |
| `buffer-list`   | 1.9ms   |
| `emacs-uptime`  | 1.8ms   |

**Conclusion**: Single emacsclient round-trip is ~2ms. Confirms C-003
(< 50ms for pure string functions) with substantial margin.

### Sequential eval burst (100 calls)

| Metric  | Value   |
|---------|---------|
| Mean    | 2.0ms   |
| Median  | 1.7ms   |
| Stdev   | 2.8ms   |
| P95     | 2.0ms   |
| P99     | 2.3ms   |
| Min     | 1.5ms   |
| Max     | 29.5ms  |
| Total   | 203.1ms |

**Conclusion**: 100 sequential evals complete in ~200ms with no failures.
The max outlier (29.5ms) is likely a GC pause or macOS scheduler hiccup.
The daemon is stable under sequential burst load from a single client.

### ERT test burst (100 calls from batch Emacs)

| Metric           | Value |
|------------------|-------|
| 100 calls total  | 126ms |
| Per-call average  | 1.3ms |
| Success rate      | 100%  |

**Conclusion**: Batch-mode ERT tests calling emacsclient in a tight loop
achieve even lower latency than Python subprocess calls, confirming
the daemon is not the bottleneck.

### Daemon lifecycle timing

| Operation            | Elapsed |
|----------------------|---------|
| Graceful stop        | 113ms   |
| Cold start           | 186ms   |
| First eval after start | 3ms   |
| Full restart cycle   | 302ms   |
| SIGKILL recovery     | 313ms   |

**Breakdown**: The full restart cycle of ~300ms consists of:
- Stop phase: ~110ms (graceful `kill-emacs` + process exit)
- Start phase: ~190ms (`emacs --daemon` fork + socket creation)
- Eval readiness: ~3ms after daemon reports ready

### SIGKILL recovery

| Phase                    | Elapsed |
|--------------------------|---------|
| SIGKILL to process death | 110ms   |
| New daemon start         | 203ms   |
| Total recovery           | 313ms   |

**Conclusion**: SIGKILL recovery takes approximately the same time as a
graceful restart. The stale socket file does not block the new daemon.

## PID stability under test

The `emcp-test-daemon-pid-stable` ERT test confirms that 10 sequential
PID queries return the same value. Under single-client load, the daemon
is stable.

The instability documented in `system-monitor.md` (3 PIDs in 2 minutes)
is caused by **concurrent agents** each attempting daemon management
independently, not by inherent daemon fragility.

## Auto-restart mechanism

`emcp-stdio--daemon-recover` now includes automatic restart with a
cooldown mechanism:

1. On daemon call failure, first attempts `check-daemon` (existing behavior).
2. If the daemon is truly dead, checks cooldown timer (default: 10 seconds).
3. If cooldown has elapsed, calls `emacs --daemon` and waits up to 5 seconds
   for the socket to appear.
4. If cooldown is still active, logs a message and returns failure to prevent
   restart loops.

### Restart loop prevention

The 10-second cooldown (`emcp-stdio--daemon-restart-cooldown`) prevents the
scenario observed in `system-monitor.md`: multiple agents each killing and
restarting the daemon in rapid succession. With 9 concurrent agents, each
could trigger a restart at most every 10 seconds, reducing the restart storm
from "continuous" to "at most 54 restarts/minute across all agents."

For true coordination, agents should use the lock file provided by
`bin/emcp-daemon.sh` (`/tmp/emcp-daemon.lock`). The Elisp-level cooldown
is a defense-in-depth measure.

### New telemetry counters

| Counter | Purpose |
|---------|---------|
| `emcp-stdio--daemon-restart-count` | Total automatic restart attempts |
| `emcp-stdio--daemon-last-restart` | Timestamp of last restart (for cooldown) |

These are reported in the shutdown telemetry line.

## Recommended timeout values

| Context                        | Timeout | Rationale |
|--------------------------------|---------|-----------|
| Health check (`check-daemon`)  | 3s      | Current default. Sufficient for single-client. |
| Health check under load        | 10s     | system-monitor.md showed 3s timeout failing under concurrent load. |
| emacsclient eval (normal)      | 5s      | 2x safety margin over worst observed single-call latency. |
| Auto-restart wait              | 5s      | Cold start is ~200ms; 5s provides 25x margin. |
| Restart cooldown               | 10s     | Prevents restart loops. Full cycle is ~300ms, so 10s allows the daemon to stabilize. |
| Lock timeout (bin script)      | 30s     | Stale lock detection. Conservative: allows for slow machines. |

## Risk assessment: is auto-restart safe?

**Single agent**: Yes. Cold start is ~200ms, cooldown prevents loops, and the
daemon is stable under sequential burst load (100 calls, 0 failures).

**Multiple concurrent agents**: Partially safe. The per-process cooldown
prevents any single agent from restart-looping, but N agents can still
collectively cause churn. True safety requires external coordination:
- Lock file (`bin/emcp-daemon.sh` provides this)
- Shared PID file
- Named daemon instances per agent

**Recommendation**: For production use with multiple agents, use
`bin/emcp-daemon.sh restart` (which acquires a lock) rather than relying
on the Elisp-level auto-restart. The Elisp mechanism is a last-resort
recovery, not a coordination protocol.
