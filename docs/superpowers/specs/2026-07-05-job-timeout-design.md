# Job Timeout / Watchdog — Design

Date: 2026-07-05

## Goal

Prevent a hung transfer from stalling a job indefinitely. Today a stuck
`zfs send | … | zfs recv` (dead peer, wedged link) blocks forever; combined with
the skip-if-held per-job lock, that means the job holds its lock and every later
run silently skips that dataset. This adds a bounded transfer timeout that kills
the stuck pipeline and lets the existing retry/failure path take over (which
releases the lock), plus SSH liveness options so metadata commands over a dead
host fail fast instead of hanging.

## Scope

- **Transfer watchdog** — an optional per-job `timeout` bounds each transfer
  attempt (`Executor#run_pipeline`); on expiry the pipeline's process tree is
  killed and the attempt fails.
- **SSH liveness guards** — always-on `ssh` options (`ConnectTimeout`,
  `ServerAliveInterval`, `ServerAliveCountMax`) that bound connect-phase and
  mid-command hangs for metadata operations, cheaply, without per-command
  timeout machinery.

Out of scope: a general wall-clock timeout on every `Executor#run` metadata
command (SSH guards cover the realistic dead-host case; revisit only if needed).

## Behavior

- A transfer timeout raises `ExecutorError("... timed out after <N>s")`. The
  existing `perform_transfer` retry loop treats it like any transfer failure:
  retried up to `max_retries` with exponential backoff, resuming from the
  destination's `receive_resume_token`. After the final attempt the job is
  `:failed` (exit 1) and `JobRunner` releases the lock — closing the silent-skip
  hole. Fail-fast is expressible as `max_retries: 0`.
- `timeout` bounds each *attempt*, not the whole job (consistent with how
  `max_retries` already composes). Worst-case wall-clock ≈
  `(max_retries + 1) × timeout` plus backoff.
- With no `timeout` set, transfer behavior is unchanged from today; the SSH
  guards still apply.

## Components

### `lib/zfsreplicate/executor.rb`

**`run_pipeline(*cmds, timeout: nil)`** — add an optional `timeout:` keyword.

- Spawn the pipeline stages with `pgroup: true` so each stage is its own
  process-group leader (pipe wiring is unaffected by process groups). Collect the
  stage pids from the wait threads.
- When `timeout` is nil: behave exactly as today (synchronous drain).
- When `timeout` is set: drain the output on a worker thread and `join(timeout)`
  it. If it completes in time, return its result as today. If it does not:
  1. `Process.kill('TERM', -pid)` for each stage pid (negative pid → the whole
     process group, catching the `ssh`/`zfs`/`mbuffer` children, not just `sh`).
  2. Wait a short grace period (constant, 5s); `Process.kill('KILL', -pid)` any
     survivors. Ignore `Errno::ESRCH` (already gone).
  3. Join the drain thread (the pipes now EOF, so it unblocks), then raise
     `ExecutorError, "pipeline timed out after #{timeout}s"`.
- Preserve the existing first-failing-stage detection for the non-timeout path.

**`Executor.remote`** — add always-on SSH liveness options to `opts`:
`-o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3`
(≈45s to detect a dead established peer). These are constants, not configurable.

### `lib/zfsreplicate/replicator.rb`

`perform_transfer` passes `timeout: @cfg.timeout` to `run_pipeline`. No other
change — the timeout surfaces as `ExecutorError` and flows through the existing
retry loop unchanged.

### `lib/zfsreplicate/config.rb`

Add a per-replication `timeout` field to `ReplicationConfig` (appended after
`bwlimit`), parsed as `r.fetch('timeout', nil)`; when present it must be a
positive integer (raise `ConfigError` otherwise). `nil` means no timeout.
`ReplicationConfig` grows from 12 to 13 fields.

## Testing

- **Watchdog kills a hung stage:** `run_pipeline('sleep 30', 'cat', timeout: 1)`
  raises `ExecutorError` matching `/timed out/` promptly (well under 30s), and
  the spawned `sleep` is gone afterward (assert no surviving process — e.g. the
  test completes fast and a follow-up wait reaps nothing).
- **No timeout / fast pipeline:** `run_pipeline('echo hi', 'cat', timeout: 5)`
  returns `"hi\n"` normally; `run_pipeline('echo hi', 'cat')` (no timeout)
  unchanged.
- **Retry integration:** an injected executor double that raises the timeout
  `ExecutorError` on the first N attempts is retried by `perform_transfer` and
  ultimately succeeds/fails per `max_retries` (reuse the existing
  injectable-sleeper retry tests).
- **Config:** `timeout` defaults to nil, parses a positive integer, rejects zero
  / negative / non-integer with `ConfigError`; existing configs still load.
- **SSH options:** `Executor.remote(...).ssh_prefix` includes
  `ConnectTimeout=10`, `ServerAliveInterval=15`, `ServerAliveCountMax=3`.
- Run via `test/run_all.rb` (Minitest 6, plain Ruby doubles — no Mock).

## Edge cases & notes

- Killing the local pipeline tears down the SSH sessions; a partial receive left
  on the destination is handled by the existing resume path (next attempt
  resumes from the token, or `zfs recv -A` clears it — already documented).
- `pgroup: true` and group-signaling are POSIX/FreeBSD-correct; `Errno::ESRCH`
  from a race (process already exited) is ignored.
- The SSH liveness options are safe defaults: keepalives only trip on genuinely
  dead peers, and a 10s connect timeout is generous for reachable hosts.

## Documentation

README: document the per-job `timeout` (seconds, default none, opt-in; kills a
stuck transfer attempt and lets retry/backoff take over), note the always-on SSH
liveness guards, and update the "Known limitations" / deferred note that
previously flagged the absence of a timeout.
