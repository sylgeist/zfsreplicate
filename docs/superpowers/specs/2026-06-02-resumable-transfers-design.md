# Resumable Transfers — Design

**Status:** Approved (brainstorm complete, pending implementation)
**Date:** 2026-06-02
**Scope:** Spec 1 of 3 in the "flesh out zfsreplicate" effort. Sibling specs (own cycles): (2) parallel execution + operational safety/UX, (3) transport tuning.

## Goal

Make a `zfs send | zfs recv` transfer survive an interrupted SSH connection instead of restarting from zero. A multi-hour initial send to a remote host that drops at 90% should continue from where it stopped — both within a single `sync` invocation and across separate (e.g. cron) runs.

## Background

OpenZFS supports resumable receives:

- The receiver enables it with `zfs recv -s`. On interruption, the partially received state is preserved and a **resume token** is exposed at `zfs get -H -o value receive_resume_token <dataset>` (the value is `-` when there is no pending resume).
- The sender continues with `zfs send -t <token>`. The token encodes the source dataset, target snapshot, and incremental base, so `-t` takes **no** `-R`/`-I`/dataset arguments.
- A pending resumable state can be discarded with `zfs recv -A <dataset>` (not used by this feature — see Error handling).

Today `Replicator#run` performs exactly one `zfs send … | zfs recv -F <dst>` and raises on any failure (the partial, if any, is left as plain `recv` with no `-s`, so it is not resumable).

## Decisions (from brainstorming)

- **Resilience model: both** in-run retry *and* cross-run pickup of a leftover token.
- **Retry policy:** exponential backoff, configurable. Default 3 retries after the first attempt (≤ 4 attempts total); base delay 5s → delays of 5s, 10s, 20s.
- **Default:** resume is **on by default**; opt out per-job with `resume: false`.
- **Structure:** logic lives in `Replicator` (private `perform_transfer` + pure command builders). No new class. An injectable sleeper keeps backoff out of test wall-clock.

## Config surface (per replication)

| Field | Default | Meaning |
|---|---|---|
| `resume` | `true` | Enable resumable transfers (`zfs recv -s` + retry/resume loop) |
| `max_retries` | `3` | Retries *after* the first attempt (≤ 4 attempts total) |
| `retry_delay` | `5` | Base seconds for exponential backoff: `delay = retry_delay * 2^(n-1)` |

- `resume: false` reproduces today's behavior exactly: one attempt, `zfs recv -F` (no `-s`), no retry.
- `Config` validation rejects negative `max_retries` / `retry_delay` (raising `ConfigError`, consistent with existing validation).

## Components & boundaries

### `Dataset#resume_token`
Runs `zfs get -H -o value receive_resume_token <name>`. Returns:
- the token string when present,
- `nil` when the value is `-` or empty,
- `nil` when the command errors (e.g. the dataset does not exist) — caught `ExecutorError`.

### Pure command builders on `Replicator` (the testable seam)
- `resume_send_command(token:)` → `zfs send -t <token>`
- `recv_command(dataset:, fresh:, resumable:)` → assembles flags: `-F` only when `fresh`, `-s` only when `resumable`. Examples:
  - `fresh: true,  resumable: true`  → `zfs recv -F -s <ds>`
  - `fresh: true,  resumable: false` → `zfs recv -F <ds>`     (today's command)
  - `fresh: false, resumable: true`  → `zfs recv -s <ds>`     (resume continuation)
- `send_command(latest:, common:, recursive:)` — unchanged, used for fresh sends.

### `Replicator#perform_transfer` (private) — the retry/resume loop
Injectable sleeper: `Replicator.new(cfg, src_executor:, dst_executor:, sleeper:)`, default `->(s) { Kernel.sleep(s) }`; tests pass a recording no-op.

```
def perform_transfer(src_exec, dst_exec, dst_ds, fresh_send:, recv_fresh:, recv_resume:)
  attempt = 0
  loop do
    token = @cfg.resume ? dst_ds.resume_token : nil
    if token
      send_cmd, recv_cmd = resume_send_command(token:), recv_resume
    elsif fresh_send
      send_cmd, recv_cmd = fresh_send, recv_fresh
    else
      return                      # nothing pending to resume
    end
    begin
      src_exec.run_pipeline(send_cmd, remote_recv_cmd(dst_exec, recv_cmd))
      return
    rescue ExecutorError => e
      attempt += 1
      raise if !@cfg.resume || attempt > @cfg.max_retries
      delay = @cfg.retry_delay * (2 ** (attempt - 1))
      logger.warn("Transfer attempt #{attempt} failed (#{e.message}); retrying in #{delay}s")
      @sleeper.call(delay)
    end
  end
end
```

## Data flow in `run`

Two phases, both routed through `perform_transfer`:

1. **Resume pending** — if `resume` and `dst_ds.resume_token` is non-nil, finish the interrupted transfer left by a previous run *before* creating a new snapshot. (Called with `fresh_send: nil`; the loop takes the token path until the partial completes, then returns.)
2. **Normal send** — create the source snapshot, list managed snapshots, compute `latest`/`common`, run the existing `-F` clobber guard, then `perform_transfer` with the fresh send/recv commands.
3. **Prune** — unchanged.

Key properties:
- A fresh send that drops mid-stream leaves a token, so the **next loop iteration in the same run** switches to `-t` resume automatically.
- Pruning keeps the newest snapshots and the in-flight snapshot is always the newest, so a leftover token is not invalidated by pruning — *except* at `keep_snapshots: 1` (see Limitations).
- With `resume: false`, `token` is always `nil`, the fresh path runs once, and the first failure re-raises — byte-for-byte today's behavior.

## Error handling

- Transfer `ExecutorError` → retried per policy; after exhaustion, re-raised. The CLI already rescues `ExecutorError` ("Replication failed", exit 1). The resumable partial remains on the destination for the next run.
- `resume_token` fetch failure (missing dataset) → treated as "no token".
- We never auto-abort (`zfs recv -A`); leaving the partial is the safe, resumable default. Operators can abort manually if they want to force a fresh send.

## Testing

- **Pure:** `resume_send_command`; `recv_command` across the three flag combinations.
- **`Dataset#resume_token`:** returns token; `nil` on `-`; `nil` on missing dataset (executor raises).
- **Integration** (recording executor with stateful `receive_resume_token` responses and scripted pipeline failures; no-op sleeper that records delays):
  - `resume: false` → single attempt, `recv -F`, raises on failure (back-compat).
  - success path uses `recv -F -s`.
  - fail-once-then-succeed → 2 attempts; sleeper called once with `5`.
  - fail past `max_retries` → raises; sleeper called with `5, 10, 20`.
  - leftover token at job start → phase-1 resume (`zfs send -t`) runs before snapshot creation.
  - fresh send interrupted (token appears after first failure) → 2nd attempt switches to `zfs send -t`.

## Docs

- README: new "Resumable transfers" section; add the three config-table rows; remove the "Resume … not yet supported" line from Known limitations.

## Limitations / non-goals

- `keep_snapshots: 1` can prune the in-flight base before a cross-run resume; documented, not handled.
- Recursive (`-R`) resumable sends rely on the OpenZFS token encoding; supported transparently via `-t` on modern OpenZFS, not separately special-cased.
- No `zfs recv -A` auto-abort and no stale-token auto-recovery in this spec.
- Compression / bandwidth limiting and parallel execution are out of scope (Specs 2 and 3).
