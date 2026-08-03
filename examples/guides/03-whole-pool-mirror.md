# Whole-pool mirror (recursive)

Mirror an entire dataset subtree — the parent and all its children — to a backup
host in a single recursive stream.

Config: [`../configs/recursive-pool.yml`](../configs/recursive-pool.yml)

## What `recursive` does

`recursive: true` passes `-R` to `zfs send`, so the stream includes every child
dataset under the source, along with their properties and snapshots. Replicating
`tank` recursively covers `tank/vms`, `tank/db`, `tank/home`, and so on, all at
once.

```yaml
source:
  dataset: tank
destination:
  host: 192.168.1.20
  user: root
  dataset: backup/tank
recursive: true
keep_snapshots: 7
```

## Run it

```sh
zfsreplicate list
# pool-mirror: tank → root@192.168.1.20:backup/tank (keep 7)

zfsreplicate -n sync pool-mirror         # dry run first
zfsreplicate -v sync pool-mirror         # real run
```

## Snapshot management with recursion

Each run snapshots the source subtree, sends an incremental stream (or a full one
the first time), and prunes managed snapshots beyond `keep_snapshots` on both
sides. Only snapshots matching `snapshot_prefix` (default `zfsreplicate`) are
touched — anything you snapshot by hand is left intact.

## Notes

- The first recursive send is a full stream; the destination subtree
  (`backup/tank`) must not already exist as populated datasets, or the job aborts
  rather than overwrite it. Opt into an overwriting `zfs recv -F` for one run
  with `zfsreplicate --force sync <job>`.
- Keep `keep_snapshots` modest for large recursive sets — it applies per dataset.
