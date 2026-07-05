# Parallel Execution + Operational Safety — Design

Date: 2026-07-05

## Goal

Let `zfsreplicate sync` run multiple replication jobs concurrently, prevent
overlapping runs of the same job from colliding, and report partial failures
through the process exit code. Jobs are already independent (each `Replicator#run`
is self-contained), so this is primarily a runner and a lock wrapped around the
existing per-job logic — `Replicator#run` itself is unchanged.

## Scope

In scope (all confirmed with the user):

1. **Parallel job execution** — a thread pool sized by `--concurrency`/`-j`
   (default 1 = today's sequential behavior).
2. **Per-job lock** — `flock` (non-blocking) per job name; a run whose lock is
   already held is *skipped*, not failed.
3. **Meaningful exit codes** — 0 all ok, 1 ≥1 job failed, 2 config/usage error.

Explicitly out of scope:

- **Run summary report** — dropped (YAGNI); status is conveyed via log lines.
- **Per-job timeout / hung-job watchdog** — deferred to its own spec. See
  "Deferred: job timeout" below.

## Architecture

```
CLI#cmd_sync
  └─ JobRunner.new(jobs, concurrency:).run { |job| run_one(job, lock_dir) }
        run_one(job):
          Lock.acquire(job.name, dir: lock_dir) do   # flock LOCK_EX|LOCK_NB
            Replicator.new(job).run                   # existing per-job logic
          end
          → outcome: :ok | :failed | :skipped
  └─ exit code derived from aggregated outcomes
```

`Replicator#run` is not modified. The concurrency, locking, and exit-code logic
live entirely in the new units and a small `cli.rb` change.

## Components

### `lib/zfsreplicate/lock.rb` — `Lock`

- `Lock.acquire(name, dir:) { ... }` opens `<dir>/<name>.lock` and calls
  `File#flock(File::LOCK_EX | File::LOCK_NB)`.
- **Held** → does not yield; returns a sentinel indicating `:skipped`. The lock
  file is *not* deleted on release (deleting it would race another process that
  has already opened the same path); the OS releases the advisory lock when the
  fd closes.
- **Acquired** → yields the block, releases (closes fd) on exit, returns the
  block's completion.
- Default `dir`: `/var/run/zfsreplicate`, created if missing. Overridable via
  top-level config key `lock_dir:` and CLI `--lock-dir DIR` (flag wins).
- If the directory cannot be created or the lock file cannot be opened, the job
  is `:failed` with a clear error message — never an uncaught crash.

### `lib/zfsreplicate/job_runner.rb` — `JobRunner`

- Pure Ruby stdlib. `JobRunner.new(items, concurrency:)`; `#run { |item| ... }`
  drains a `Queue` of items with a fixed pool of `concurrency` worker threads.
  Items are replication configs that respond to `#name` (JobRunner uses the name
  for tagging and outcome records; it stays otherwise agnostic about the item).
- Each worker sets a thread-local job tag (`Thread.current[:zfsreplicate_job]`)
  from `item.name` before invoking the block, so interleaved log lines are
  attributable, then records `{ name:, status:, error: }`.
- The block is expected to return an outcome symbol (`:ok`/`:skipped`) or raise;
  a raised `ExecutorError` (or any `StandardError`) is caught, logged as ERROR,
  and recorded as `:failed` — one job's failure never stops the others
  (continue-all-aggregate).
- `#run` returns the list of outcomes (order not guaranteed).
- `concurrency: 1` uses a single worker → all jobs run, sequentially; behavior
  matches today.

### `lib/zfsreplicate/log.rb` — formatter change

- Formatter includes the thread-local job tag when set:
  `[INFO] zfsreplicate(vms-backup): ...`. With no tag set the format is
  unchanged (`[INFO] zfsreplicate: ...`), preserving existing non-sync output.

### `lib/zfsreplicate/cli.rb` — wiring

- Add `-j`, `--concurrency N` (Integer) option.
- Read a top-level `concurrency:` key from config (see Config below); the CLI
  flag overrides it; default 1.
- Add `--lock-dir DIR` option; overrides config `lock_dir:`; default
  `/var/run/zfsreplicate`.
- `cmd_sync` selects the jobs (as today), runs them through `JobRunner`, then
  maps aggregated outcomes to the exit code.

### `lib/zfsreplicate/config.rb` — top-level keys

- Parse two optional top-level keys alongside `replications`:
  - `concurrency:` — non-negative integer, default 1 (reuse existing
    `non_negative_int` validation; a value of 0 is treated as 1).
  - `lock_dir:` — string path, default `/var/run/zfsreplicate`.
- These are run-level settings, exposed on the `Config` object (not per
  replication). Unknown/missing → defaults. Existing configs keep working.

## Failure model & exit codes

- Continue-all-aggregate: each job's `ExecutorError`/`StandardError` is caught
  per job, logged ERROR, recorded `:failed`; remaining jobs proceed.
- **Skip** (lock held) is logged at WARN (`job X already running, skipping`) and
  recorded `:skipped`. Skipped ≠ failed.
- Exit codes:
  - `0` — no job failed (all `:ok`, or a mix of `:ok`/`:skipped`).
  - `1` — one or more jobs `:failed`.
  - `2` — config/usage error raised before jobs start (unchanged from today:
    `ConfigError`, unknown command, no matching job).

## Logging under concurrency

`Logger` serializes writes internally (its log device holds a mutex), so
concurrent `logger.info` calls from worker threads are safe. The only change
needed for readability is the per-job tag via thread-local state, above.

## Testing

- **Lock**: acquire then release; a second `acquire` while the first fd holds the
  lock returns `:skipped` (hold the fd in-process or fork a child); unwritable /
  uncreatable `dir` yields a job-level error rather than a crash.
- **JobRunner**: with N fake job blocks and concurrency K, all N run; a block
  that raises is recorded `:failed` and does not stop the others; outcomes
  aggregate correctly; `concurrency: 1` runs all jobs. Assertions are on
  outcomes/counts (deterministic), not timing. Fake blocks do no real ZFS work,
  matching the existing injectable-executor test style.
- **Config**: `concurrency`/`lock_dir` parse with defaults; `concurrency`
  reuses non-negative-int validation; missing keys → defaults; existing configs
  still load.
- **CLI**: exit-code mapping (all-ok → 0, one-fail → 1, config error → 2) with a
  stubbed runner; `-j` flag overrides config `concurrency`.
- Run via `test/run_all.rb` (Minitest 6, plain Ruby doubles — no Mock).

## Documentation

- README: document `-j`/`--concurrency`, `--lock-dir`, config `concurrency:` and
  `lock_dir:`, the skip-if-held behavior, and the exit-code contract. Remove the
  "Jobs run sequentially; no parallelism" line from Known limitations.
- Optionally add a `multi-job` note to `examples/` referencing `-j`.

## Deferred: job timeout

There is currently no per-job timeout; a hung `zfs send | zfs recv` runs
indefinitely. Combined with skip-if-held locking, a permanently hung job would
hold its lock and cause every later run to skip that dataset — a backup could
silently stop. This is judged uncommon and is deferred to its own spec. Mitigation
in the meantime: skips are logged at WARN, so a hung job surfaces as repeated
"already running, skipping" log lines. A future timeout spec must handle killing
the whole `Open3.pipeline_r` process group (send, recv, and the SSH child) and
FreeBSD process-group signal semantics.
