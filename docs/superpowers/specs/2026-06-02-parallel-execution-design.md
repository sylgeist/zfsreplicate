# Parallel Execution + Operational UX — Design

**Status:** Approved (brainstorm complete, pending implementation)
**Date:** 2026-06-02
**Scope:** Spec 2 of 3. Sibling specs: (1) resumable transfers — DONE (merged); (3) transport tuning — not started.

## Goal

Run independent replication jobs concurrently (capped) instead of strictly sequentially, so a fast source fanning out to several lower-bandwidth nodes finishes in roughly the time of the slowest node rather than the sum of all nodes. Add the operational pieces that make concurrent, unattended (cron) runs safe and legible: a per-job lock to prevent overlapping runs, an end-of-run summary, and meaningful exit codes.

## Background

Today `CLI.cmd_sync` iterates jobs sequentially, calling `Replicator.new(rep).run` for each, and exits 1 on the first `ConfigError`/`ExecutorError`. Jobs are independent (each is one source→destination `Replicator#run`) and share no mutable state, which makes them safe to run in parallel. The work is IO-bound: each job spends ~all its time inside `zfs`/`ssh` subprocesses via `Open3`, and Ruby releases the GIL during that external wait — so threads achieve real parallelism here.

## Decisions (from brainstorming)

- **Concurrency:** thread pool, `min(concurrency, job_count)` workers. `--concurrency N` / `-j N` flag overrides a top-level `concurrency` config key; default **1** (sequential = today's behavior).
- **Locking:** per-job `flock`, **skip if held** (a held lock means another process is already running that job; skip it with a warning, run the rest).
- **Exit codes:** `0` = no failures (skips allowed); `1` = any job failed; `2` = config/usage error.
- **Summary:** per-job table (name, status, duration; error message on failure), printed every run.
- **Continue-on-failure:** a failed job never aborts its siblings.
- **Per-job log tagging:** concurrent log lines are prefixed `[job-name]` via a thread-local, leaving `Replicator` untouched.

### Why `flock`, not a `Mutex`
A `Mutex`/`ConditionVariable` is in-process only — it coordinates threads within one `sync` run and is used for that (guarding result collection). It cannot prevent a *separate* cron-spawned process from starting an overlapping run, because each process has its own Mutex in its own memory. The overlap guard must be an OS-level primitive both processes can see: `flock` (kernel-held, auto-released on process death). The two are complementary, used at different scopes.

## Components & files

### `Lock` — `lib/zfsreplicate/lock.rb`
Non-blocking advisory lock over a per-job file.
```ruby
class Lock
  def initialize(path); @path = path; end

  def acquire
    @file = File.open(@path, File::CREAT | File::RDWR, 0o644)
    !!@file.flock(File::LOCK_EX | File::LOCK_NB)   # 0 on success (truthy) → true; false if held
  rescue SystemCallError
    false
  end

  def release
    return unless @file
    @file.flock(File::LOCK_UN)
    @file.close
    @file = nil
  end
end
```
Lock file path = `File.join(lock_dir, "#{sanitize(name)}.lock")`, where `sanitize` replaces `[^A-Za-z0-9_.-]` with `_`. `flock` auto-releases when the fd closes or the process dies, so stale lock files are harmless.

### `JobRunner` — `lib/zfsreplicate/job_runner.rb`
Thread pool + result aggregation. Holds the result struct:
```ruby
JobResult = Struct.new(:name, :status, :duration, :error)  # status ∈ :ok, :failed, :skipped
```
Constructor (dependencies injected for testing):
```ruby
def initialize(jobs, concurrency:,
               execute: ->(job) { Replicator.new(job).run },
               lock_factory:,                 # ->(name) { Lock.new(path_for(name)) }
               clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
```
`run`:
```ruby
def run
  queue = Queue.new
  @jobs.each { |j| queue << j }
  results = []
  mutex = Mutex.new
  workers = Array.new([@concurrency, @jobs.size].min) do
    Thread.new do
      loop do
        job = begin; queue.pop(true); rescue ThreadError; break; end
        r = run_one(job)
        mutex.synchronize { results << r }
      end
    end
  end
  workers.each(&:join)
  results
end
```
`run_one`:
```ruby
def run_one(job)
  Thread.current[:zfsreplicate_job] = job.name
  lock = @lock_factory.call(job.name)
  unless lock.acquire
    ZFSReplicate.logger.warn("Skipping #{job.name}: already running")
    return JobResult.new(job.name, :skipped, 0.0, nil)
  end
  start = @clock.call
  begin
    @execute.call(job)
    JobResult.new(job.name, :ok, @clock.call - start, nil)
  rescue StandardError => e
    ZFSReplicate.logger.error("#{job.name} failed: #{e.message}")
    JobResult.new(job.name, :failed, @clock.call - start, e.message)
  ensure
    lock.release
    Thread.current[:zfsreplicate_job] = nil
  end
end
```
Note: `rescue StandardError` (not just `ExecutorError`) so an unexpected bug in one job is recorded as a failure rather than killing the worker thread and aborting the run.

### `Report` — `lib/zfsreplicate/report.rb`
Pure formatting, printed to **stdout** (logs stay on stderr).
```ruby
module Report
  def self.summary_lines(results)
    # returns an Array<String>:
    #   "Summary:"
    #   "  <name>  <status>  <duration>  [<error>]"   (duration "-" for skipped)
    #   "<n> ok, <m> failed, <k> skipped"
  end
end
```
Status rendering: `ok`, `FAILED` (upcased to stand out), `skipped`. Duration `"%.1fs"`; skipped shows `-`. Failed rows append the error message.

### `Config` — `lib/zfsreplicate/config.rb`
Two new optional top-level keys (siblings of `replications`), with readers:
- `concurrency` (default `1`) — validated positive integer (`>= 1`), else `ConfigError`.
- `lock_dir` (default `File.join(Dir.tmpdir, "zfsreplicate-locks")`).

### `CLI` — `lib/zfsreplicate/cli.rb`
- New option `-j` / `--concurrency N` (parsed to Integer; `< 1` → usage error, exit 2).
- New pure helper `CLI.exit_code_for(results)` → `1` if any result `:failed`, else `0`.
- `cmd_sync` rewrite (see Data flow).
- `ConfigError` handling exits `2` (was 1).

### `log.rb`
Formatter appends a per-job tag when the thread-local is set:
```ruby
l.formatter = lambda do |sev, _t, prog, msg|
  tag = Thread.current[:zfsreplicate_job]
  prefix = tag ? "#{prog}[#{tag}]" : prog
  "[#{sev}] #{prefix}: #{msg}\n"
end
```
This tags all of `Replicator`'s existing log output automatically; `Replicator` is unchanged.

## Data flow (`cmd_sync`)

1. Load config (`ConfigError` → exit 2).
2. Select jobs by name (or all). None match / none configured → warn, exit 2 (usage).
3. Resolve concurrency: `options[:concurrency] || cfg.concurrency` (already defaulted to 1).
4. If `--dry-run`: print planned actions sequentially (no threads, no locks); exit 0.
5. Else: build `lock_factory` from `cfg.lock_dir` (mkdir_p on demand), construct `JobRunner`, `run`.
6. Print `Report.summary_lines(results)` to stdout.
7. `exit CLI.exit_code_for(results)` (0 or 1).

## Error handling

- Per-job: `StandardError` caught in `run_one` → `:failed` (+message), siblings unaffected.
- Lock held → `:skipped` (warning, not a failure; does not affect exit code).
- Config/usage (`ConfigError`, bad `--concurrency`, unknown job) → exit 2 before any job runs.
- Lock release is in `ensure`; `flock` also auto-releases on process death.

## Testing

- **`Lock`** (real flock in a tempdir): a second `acquire` on the same path returns false while the first is held; after `release`, a fresh acquire succeeds.
- **`JobRunner`** (injected `execute`/`lock_factory`/`clock`):
  - all jobs succeed → all `:ok`.
  - one job's `execute` raises → that job `:failed` (message captured), the others still `:ok`.
  - a job whose lock `acquire` returns false → `:skipped`, and `execute` not called for it.
  - `concurrency: 2` with 4 jobs → all 4 executed (every job appears in results exactly once).
- **`Report.summary_lines`**: mixed ok/failed/skipped renders the rows, the failed error, and the correct totals line.
- **`Config`**: `concurrency` default 1; parses a valid value; rejects `0`/negative/non-integer (`ConfigError`); `lock_dir` default and override.
- **`CLI`**: `--concurrency`/`-j` parses into options; `< 1` exits 2; `exit_code_for` returns 1 when any `:failed`, else 0.

Full threaded `cmd_sync` is exercised through `JobRunner` (with a fake `execute`), so no test requires a live ZFS/SSH.

## Docs

- README: a "Parallel execution" section (the `--concurrency` flag, the `concurrency`/`lock_dir` config keys, locking/skip behavior, exit codes, sample summary output); add the config-table rows; remove "Jobs run sequentially; no parallelism" from Known limitations.

## Limitations / non-goals

- Bytes-transferred and full-vs-incremental in the summary are out of scope (would need `zfs send -v` parsing); status + duration only.
- No bandwidth limiting or compression (Spec 3). Parallelism over a *shared* bottleneck link won't speed totals; this spec doesn't try to.
- Lock granularity is per job name; renaming a job mid-flight is not protected against.
- `--concurrency` is a single global cap, not per-job or per-destination weighting.
