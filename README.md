# zfsreplicate

A Ruby CLI for replicating ZFS datasets between nodes over SSH. No gems required — Ruby stdlib and FreeBSD base system tools only.

## Requirements

- Ruby >= 3.0
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

Create `~/.config/zfsreplicate/config.yml`:

```yaml
replications:
  - name: vms-backup
    source:
      host: 192.168.1.10      # omit for local dataset
      user: root
      dataset: tank/vms
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
| `destination.dataset` | yes | — | ZFS dataset path on destination |
| `destination.host` | no | *(local)* | Remote host; omit for local dataset |
| `destination.user` | no | `root` | SSH user |
| `destination.port` | no | `22` | SSH port |
| `recursive` | no | `false` | Pass `-R` to `zfs send` |
| `keep_snapshots` | no | `7` | Number of managed snapshots to retain on each side |
| `snapshot_prefix` | no | `zfsreplicate` | Prefix for auto-created snapshot names |

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
  sync [name]         Run replication job(s). Omit name to run all.
  list                List configured replications.
  help                Show this message.

Options:
  -c, --config FILE   Config file (default: ~/.config/zfsreplicate/config.yml)
  -v, --verbose       Verbose output
  -n, --dry-run       Print actions without executing
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

### Run a specific replication

```sh
zfsreplicate sync vms-backup
```

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
4. Sends an **incremental** stream (`zfs send -I`) if a common snapshot exists, or a **full** stream if the destination is empty
5. Prunes old managed snapshots on both sides, keeping the most recent `keep_snapshots`

If the destination has managed snapshots but shares none with the source, the job aborts with an error — this requires manual intervention (e.g. `zfs destroy` stale snapshots on the destination before re-running).

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

## Known limitations

- Resume (`zfs send -s` / `zfs recv -s`) is not yet supported
- Pipeline exit status reflects only the last command (`zfs recv`); a silent `zfs send` failure will not be caught until the next sync detects missing snapshots
- Jobs run sequentially; no parallelism
