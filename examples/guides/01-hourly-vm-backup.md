# Hourly VM backup: local → remote

Replicate a local VM dataset (`tank/vms`) to a remote backup server every hour.

Config: [`../configs/local-to-remote.yml`](../configs/local-to-remote.yml)

## 1. Set up SSH key auth

zfsreplicate connects with `BatchMode=yes` — no password prompts. Generate a
key on the source host and install it on the destination:

```sh
ssh-keygen -t ed25519 -f /root/.ssh/replicate_key -N ''
ssh-copy-id -i /root/.ssh/replicate_key.pub root@192.168.1.20
```

Verify it works non-interactively before going further:

```sh
ssh -o BatchMode=yes -i /root/.ssh/replicate_key root@192.168.1.20 echo ok
# ok
```

## 2. Write the config

Copy [`../configs/local-to-remote.yml`](../configs/local-to-remote.yml) to
`/usr/local/etc/zfsreplicate/config.yml` (or keep it anywhere and pass `-c`). Adjust
the destination host, datasets, and `identity` path to match your setup.

## 3. Confirm what will run

```sh
zfsreplicate list
# vms-backup: tank/vms → root@192.168.1.20:backup/vms (keep 14)

zfsreplicate -n sync
# [dry-run] Would replicate tank/vms → backup/vms
```

## 4. First real sync

The first run has no common snapshot, so it sends a **full** stream (the
destination `backup/vms` must not already exist as a populated dataset).
Subsequent runs send only **incremental** changes.

```sh
zfsreplicate -v sync vms-backup
# [INFO] zfsreplicate: Creating snapshot tank/vms@zfsreplicate-...
# [INFO] zfsreplicate: Sending zfsreplicate-... (full)
```

## 5. Schedule it

```
# /etc/crontab — every hour on the hour
0 * * * * root /usr/local/bin/zfsreplicate sync >> /var/log/zfsreplicate.log 2>&1
```

## 6. Verify

```sh
# On the destination: snapshots should accumulate under the prefix
ssh root@192.168.1.20 zfs list -t snapshot -o name backup/vms
```

Old managed snapshots beyond `keep_snapshots: 14` are pruned automatically on
both sides each run. Snapshots that don't match `snapshot_prefix` are left alone.
