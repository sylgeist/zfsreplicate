# zfsreplicate

A Ruby CLI for replicating ZFS datasets between nodes over SSH. No gems required — Ruby stdlib and FreeBSD base system tools only.

## Requirements

- Ruby >= 4.0
- FreeBSD (or any OS with `zfs(8)` in PATH)
- `ssh(1)` with key-based auth configured between nodes

## Installation

```sh
git clone https://github.com/sylgeist/zfsreplicate.git
chmod +x zfsreplicate/bin/zfsreplicate
```

Optionally symlink into your PATH:

```sh
ln -s /path/to/zfsreplicate/bin/zfsreplicate /usr/local/bin/zfsreplicate
```

## Configuration

Create `/usr/local/etc/zfsreplicate/config.yml`:

```yaml
replications:
  - name: vms-backup
    source:
      host: 192.168.1.10      # omit for local dataset
      user: root
      dataset: tank/vms
      identity: /root/.ssh/replicate_key   # optional SSH key
    destination:
      host: 192.168.1.20
      user: root
      dataset: backup/vms
    recursive: false
    keep_snapshots: 14
    snapshot_prefix: zfsreplicate
```

Use a different config file with `-c`:

```sh
zfsreplicate -c /etc/zfsreplicate.yml list
```

### Configuration reference

| Field | Required | Default | Description |
|---|---|---|---|
| `name` | yes | — | Job identifier used with `sync <name>` |
| `source.dataset` | yes | — | ZFS dataset path (e.g. `tank/vms`) |
| `source.host` | no | *(local)* | Remote host; omit for local dataset |
| `source.user` | no | `root` | SSH user |
| `source.port` | no | `22` | SSH port |
| `source.identity` | no | *(ssh default)* | Path to an SSH private key (`ssh -i`) |
| `destination.dataset` | yes | — | ZFS dataset path on destination |
| `destination.host` | no | *(local)* | Remote host; omit for local dataset |
| `destination.user` | no | `root` | SSH user |
| `destination.port` | no | `22` | SSH port |
| `destination.identity` | no | *(ssh default)* | Path to an SSH private key (`ssh -i`) |
| `recursive` | no | `false` | Replicate the dataset and all its children: snapshots are created/destroyed with `-r` and sent with `zfs send -R`, so retention applies to the whole subtree |
| `keep_snapshots` | no | `7` | Number of managed snapshots to retain on each side (minimum `1`) |
| `snapshot_prefix` | no | `zfsreplicate` | Prefix for auto-created snapshot names |
| `force` | no | `false` | Permanently permit a full `zfs recv -F` to a destination that already exists but shares no snapshot (overwrites it). Prefer the one-shot `--force` CLI flag — this key disarms the guard on every run and is warned about at startup |
| `resume` | no | `true` | Use `zfs recv -s` and retry/resume interrupted transfers |
| `max_retries` | no | `3` | Retries after the first attempt (≤ 4 tries total) |
| `retry_delay` | no | `5` | Base seconds for exponential backoff (5s, 10s, 20s…) |
| `compressed_send` | no | `true` | Send blocks in their on-disk compressed form (`zfs send -c`); set `false` if the receiver lacks the compression feature |
| `bwlimit` | no | *(none)* | Throttle transfer rate via a local `mbuffer -R` stage (e.g. `50m`, `1G`); requires `mbuffer` (`pkg install mbuffer`) on the host running zfsreplicate |
| `timeout` | no | *(none)* | Kill a transfer attempt stuck longer than this many seconds and let retry/backoff take over; set with `max_retries: 0` for fail-fast |

Job names must be unique (they key the per-job lock files), and unrecognized
config keys are warned about at startup — a typo like `keep_snapshot:` is
surfaced instead of silently applying the default.

Top-level keys (siblings of `replications`):

| Field | Required | Default | Description |
|---|---|---|---|
| `concurrency` | no | `1` | Max replication jobs to run in parallel |
| `lock_dir` | no | *(temp dir)* | Directory for per-job lock files (`<lock_dir>/<job>.lock`) |

## Transport tuning

Two per-job settings tune how the stream is sent:

- **`compressed_send`** (default `true`) adds `-c` to `zfs send`, so already
  compressed dataset blocks travel in compressed form instead of being
  decompressed onto the wire — less bandwidth, no extra CPU. Set it to `false`
  when the destination pool lacks the relevant compression feature, or when you
  want the destination to recompress with a different setting.
- **`bwlimit`** caps throughput by piping the stream through `mbuffer -R` on the
  host running zfsreplicate (e.g. `bwlimit: 50m`). It requires `mbuffer`
  (`pkg install mbuffer`); without `bwlimit` set, `mbuffer` is not needed.

## Timeouts and liveness

Set a per-job `timeout` (seconds) to bound a single transfer attempt. If a
`zfs send | zfs recv` hangs longer than `timeout`, its process group is killed
and the attempt fails; with `resume` on (the default) the transfer is retried
from where it stopped, up to `max_retries`. Without `timeout`, a stuck transfer
can block indefinitely. There is no default timeout — set one to match your
expected worst-case transfer time.

Regardless of `timeout`, SSH connections use `ConnectTimeout=10` and
`ServerAliveInterval=15`/`ServerAliveCountMax=3`, so metadata commands against an
unreachable or newly-dead host fail within seconds instead of hanging.

### Snapshot naming

Snapshots are named `<dataset>@<prefix>-YYYYMMDD-HHMMSS` in UTC, e.g.:

```
tank/vms@zfsreplicate-20260420-153000
```

Only snapshots matching the configured prefix are managed (created, compared, pruned). Manually created snapshots are left untouched.

## Usage

```
zfsreplicate [options] <command> [args]

Commands:
  sync [name ...]     Run replication job(s). Names may be globs
                      (e.g. 'rhea-*'); omit to run all.
  list                List configured replications.
  help                Show this message.

Options:
  -c, --config FILE   Config file (default: /usr/local/etc/zfsreplicate/config.yml)
  -v, --verbose       Verbose output
  -n, --dry-run       Print actions without executing
  -j, --concurrency N Run up to N jobs in parallel (default 1)
      --host HOST     Only jobs whose source or destination endpoint
                      matches HOST (glob allowed, e.g. '*.risei.net')
      --force         Permit full-send overwrite of existing destinations
                      for this run only (requires job names or --host)
      --lock-dir DIR  Directory for per-job lock files (overrides config lock_dir)
  -V, --version       Print version and exit
```

### List configured replications

```sh
zfsreplicate list
# vms-backup: root@192.168.1.10:tank/vms → root@192.168.1.20:backup/vms (keep 14)
```

### Run all replications

```sh
zfsreplicate sync
```

### Run specific replications

```sh
zfsreplicate sync vms-backup            # one job by exact name
zfsreplicate sync 'rhea-*'              # every job whose name matches the glob
zfsreplicate sync 'rhea-*' io-git       # several selectors (union)
zfsreplicate --host rhea.risei.net sync # every job with that source or
                                        # destination host (glob allowed)
```

Name selectors and `--host` combine as AND: `sync '*-git' --host rhea.risei.net`
runs only git jobs touching rhea. Quote globs so the shell doesn't expand them.
The selected set runs through the normal scheduler, so `-j` parallelism and the
single end-of-run summary apply.

See [`examples/`](examples/) for complete, copy-paste-ready configs and
walkthroughs (local→remote, offsite-with-resume, recursive pool mirror, and more).

### Dry run

```sh
zfsreplicate -n sync
# [dry-run] Would replicate tank/vms → backup/vms
```

### Verbose output

```sh
zfsreplicate -v sync vms-backup
# [INFO] zfsreplicate: Creating snapshot tank/vms@zfsreplicate-20260420-153000
# [INFO] zfsreplicate: Sending zfsreplicate-20260420-153000 (incremental)
```

## How replication works

Each `sync` run:

1. Creates a new timestamped snapshot on the source dataset
2. Lists managed snapshots on source and destination
3. Finds the most recent common snapshot (by tag)
4. Sends an **incremental** stream (`zfs send -I`) if a common snapshot exists, or a **full** stream if the destination is empty. If the destination already holds the latest snapshot (possible with future-dated snapshots or clock skew, which also log a warning), the transfer is skipped with an INFO line and the run continues to pruning
5. Verifies the destination now holds the latest snapshot (a resumed stream can
   cover only part of an incremental package; if the destination is still
   behind, the job fails with a re-run hint instead of pruning). For recursive
   jobs this extends to the whole subtree: every child holding the latest
   snapshot on the source must hold it on the destination too, so a child the
   destination never received (e.g. a boot environment created after an
   incremental seed) fails the job by name instead of surfacing runs later as
   a cryptic `zfs recv` error
6. Prunes old managed snapshots on both sides, keeping the most recent `keep_snapshots`

If there is no common snapshot and the destination dataset **already exists**, the job aborts rather than overwriting it with a full `zfs recv -F`. To opt into the overwrite, re-run with the one-shot `--force` flag naming the jobs (`zfsreplicate --force sync 'rhea-*'`) — or `zfs destroy` the stale destination first. `--force` deliberately refuses to run without a job selection, so a forced run always says what it is forcing. A full send to a destination that does not yet exist is always allowed.

When **both** endpoints are remote, the stream is relayed through the host running `zfsreplicate` (source → here → destination) rather than sent host-to-host; run the tool on one of the two nodes to avoid the extra hop.

## Resumable transfers

By default each transfer uses `zfs recv -s`, so an interrupted `zfs send | zfs
recv` can continue from where it stopped instead of restarting:

- If a transfer fails, it is retried up to `max_retries` times with exponential
  backoff (`retry_delay`, doubling each time). On a retry the destination's
  `receive_resume_token` is used to resume rather than resend from scratch.
- If the whole run still fails, the partially received state is left on the
  destination; the next `sync` detects the leftover token and continues it
  before doing anything else.

Set `resume: false` on a job to restore the old behavior (a single attempt with
`zfs recv -F`, no retries).

To discard a stuck partial receive and force a fresh send, run
`zfs recv -A <destination-dataset>` on the destination before the next sync.
If a resume token can never succeed (its source snapshot was destroyed, or the
token is corrupt), the job detects this, skips the pointless retries, and the
error message names that exact `zfs recv -A` command.

## Parallel execution

By default jobs run one at a time. Raise the cap to replicate multiple datasets
at once — most useful when a fast source fans out to several slower destinations,
where total time drops toward the slowest single job instead of their sum:

```sh
zfsreplicate -j 4 sync        # up to 4 jobs at once
```

The cap can also be set in config (`concurrency: 4`); the `-j` flag overrides it.

When several jobs replicate the **same source dataset** to different
destinations, give each job its own `snapshot_prefix`. With a shared prefix the
jobs create and prune one shared snapshot set, so one job's pruning can destroy
the only snapshot another destination has in common once it falls more than
`keep_snapshots` runs behind.

Changing `snapshot_prefix` on an already-deployed job starts a new snapshot
lineage: the next run has no common snapshot under the new prefix, so it either
trips the full-send guard or (if run with `--force`) does a full resend that
rolls the destination back. Old-prefix snapshots are no longer managed — destroy them
manually once the new lineage is established.

Each job takes a per-job lock (`<lock_dir>/<job>.lock`) for the duration of its
run. If a job is already running in another process (for example, a still-running
previous cron invocation), it is **skipped** with a warning rather than run twice.

At the end of a run a summary is printed and the exit code reflects the outcome:

```
Summary:
  vms-backup   ok        12.3s
  node-b       FAILED     4.1s   pipeline failed (status 1): ...
  node-c       skipped       -   already running
2 ok, 1 failed, 1 skipped
```

Exit codes: `0` all jobs succeeded (skips are not failures), `1` one or more
jobs failed, `2` a configuration or usage error (nothing ran).

## SSH setup

The tool connects with `BatchMode=yes` (no password prompts). Ensure key-based auth is working before running:

```sh
ssh -o BatchMode=yes root@192.168.1.10 echo ok
```

## Running as a cron job

```
# /etc/crontab — replicate every hour
0 * * * * root /usr/local/bin/zfsreplicate sync >> /var/log/zfsreplicate.log 2>&1
```

## Running tests

```sh
ruby -Ilib -Itest test/run_all.rb
```

The unit suite fakes the executor boundary, so it cannot catch mistakes about
real `zfs` exit codes or stream semantics. Before a release, also run the live
smoke test on a ZFS host (FreeBSD box, jail, or VM) — it builds two disposable
file-backed pools and exercises bootstrap, incremental send, recursive
coverage, retention, the full-send guard, and interrupt/resume end to end:

```sh
sudo sh test/smoke_test.sh
```

It needs root, ~1 GB of temp space, and (for the resume scenario only)
`mbuffer`. Pools and temp files are destroyed on exit.

## Known limitations

- When both endpoints are remote, the stream is relayed through the orchestrating host

## License

MIT — see [LICENSE](LICENSE).
