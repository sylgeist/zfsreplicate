# Transport Tuning — Design

Date: 2026-07-05

## Goal

Reduce the time and bandwidth a replication transfer costs, via two independent
per-job levers:

1. **Compressed send** (`compressed_send`, default `true`) — add `-c` to
   `zfs send` so blocks travel in their on-disk compressed form instead of being
   decompressed onto the wire. Reuses the dataset's existing compression at zero
   extra CPU.
2. **Bandwidth limit** (`bwlimit`, default unset) — insert a local
   `mbuffer -q -R <rate>` stage into the transfer pipe to cap throughput (and
   smooth bursts). Requires generalizing `Executor#run_pipeline` from a fixed
   two-stage pipe to N stages.

## Constraints

- No RubyGems / bundler. Ruby stdlib only, as today.
- External **system binaries installable via FreeBSD `pkg`** are acceptable.
  `mbuffer` is such a binary and is a dependency **only when `bwlimit` is set**.
  `zfs send -c` is base ZFS — no new dependency.

## Rationale (compressed send vs external compression)

Plain `zfs send` ships the logical, decompressed stream. `zfs send -c` ships the
stored compressed records as-is: wire savings ≈ the dataset's compression ratio,
no decompress/recompress CPU, no decompressor needed on the receiver. Because the
target datasets here are always compressed, `-c` captures the compression win
that an external `zstd`/`ssh -C` pipe would chase — without the pipeline
complexity or the double-compression waste of stacking a compressor on already
compressed data. External stream compression is therefore **out of scope**.

## Architecture

The transfer pipe becomes:

```
[maybe-ssh] zfs send -c … | mbuffer -q -R <rate> | [maybe-ssh] zfs recv
```

`mbuffer` always runs **locally on the orchestrating host** (the middle of the
pipe). That single placement works for every topology:

- local → remote: throttles the upload
- remote → local: throttles the download
- both remote (relayed through this host): throttles the relayed stream
- local → local: throttles the local copy

`-c` is a `zfs send` flag; `zfs recv` is unchanged.

## Components

### `lib/zfsreplicate/executor.rb` — `run_pipeline`

Generalize `run_pipeline(src_cmd, dst_cmd)` to `run_pipeline(*stage_cmds)`
(N ≥ 2). Each stage runs via `/bin/sh -c` and is wired with `Open3.pipeline_r`,
exactly as today but over a list. Preserve the current behavior:

- shared stderr pipe across all stages,
- collect every stage's wait-status and raise `ExecutorError` on the **first
  failing stage** (so a failed `zfs send` is not masked by a successful `recv`).

Two-stage callers are unaffected (`run_pipeline(send, recv)` still valid).

### `lib/zfsreplicate/replicator.rb`

- **`send_command`** (full and `-I` incremental) gains a `compressed:` parameter;
  when true it inserts `-c` (e.g. `zfs send -c -I …`, `zfs send -c …`).
- **`resume_send_command`** (`zfs send -t <token>`) stays bare — the resume token
  already encodes the send parameters, so `-c` must **not** be added there.
- **`perform_transfer`** builds the stage list and runs it:
  ```
  stages = [send_cmd, bwlimit_stage, remote_recv_cmd(dst_exec, recv_cmd)].compact
  src_exec.run_pipeline(*stages)
  ```
  where `bwlimit_stage = "mbuffer -q -R #{@cfg.bwlimit}"` when `@cfg.bwlimit`,
  else `nil`.
- **Pre-flight mbuffer check:** when `bwlimit` is set, verify `mbuffer` is on
  PATH once before transferring (`command -v mbuffer` via the local executor);
  if absent, raise `ExecutorError` with a clear message
  (`bwlimit is set but 'mbuffer' is not installed`) instead of letting the pipe
  fail cryptically.

### `lib/zfsreplicate/config.rb`

Add two per-replication fields to `ReplicationConfig`:

- `compressed_send` — boolean, `r.fetch('compressed_send', true)`.
- `bwlimit` — string or nil, `r.fetch('bwlimit', nil)`; passed verbatim to
  `mbuffer -R`. No format validation beyond "present and a string" — mbuffer
  validates the rate and its error surfaces through the pipeline.

`ReplicationConfig` grows from 10 to 12 fields; update the `Struct.new` field
list and the `ReplicationConfig.new(...)` call in `parse_replication`.

## Behavior changes & edge cases

- **`compressed_send` defaults to `true`**, so existing configs start sending
  `-c` on upgrade (an intentional opt-out default). A receiver whose pool lacks
  the relevant compression feature must set `compressed_send: false`. Documented
  in the README.
- `-c` is omitted on resume-token sends (correctness, not just optimization).
- `mbuffer` is required only when `bwlimit` is set.
- `bwlimit` composes with `compressed_send`, recursion (`-R`), incrementals, and
  resume/retry (the pipe is rebuilt per attempt; the mbuffer stage is stateless).

## Testing

- **Send builders:** `-c` present on full and incremental sends when
  `compressed: true`; absent when `compressed: false`; absent on the
  resume-token send regardless.
- **`run_pipeline` N-stage:** a 3-stage pipeline streams end to end; a non-zero
  exit injected in the middle stage and in the last stage each raise
  `ExecutorError` (extend the existing pipeline tests, which use small shell
  commands like `printf`/`cat`/`false`).
- **bwlimit wiring:** `perform_transfer` includes the `mbuffer -q -R <rate>`
  stage when configured and omits it otherwise (assert on the stages passed to a
  stubbed executor); the mbuffer-missing pre-flight raises the clear error
  (inject a fake PATH/`command -v` result).
- **Config:** defaults (`compressed_send` true, `bwlimit` nil) and explicit
  parsing of both fields; existing configs still load.
- Run via `test/run_all.rb` (Minitest 6, plain Ruby doubles — no Mock).

## Out of scope

- External stream compression (`zstd`/`ssh -C`) — superseded by `zfs send -c`.
- Configurable mbuffer memory/block size (`-m`/`-s`) — rate limit only for now;
  can be added later if throughput needs tuning.
- `mbuffer` on remote endpoints — it runs only on the orchestrating host.
