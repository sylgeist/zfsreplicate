# Examples

Copy-paste-ready configurations and walkthroughs for common `zfsreplicate`
setups. For the full field/command reference, see the [main README](../README.md).

Every config here uses only currently-supported fields and is checked by
`test/test_examples.rb`, which asserts each one loads cleanly.

## Scenarios

| Scenario | Config | Guide |
|---|---|---|
| Push a local dataset to a remote host | [`configs/local-to-remote.yml`](configs/local-to-remote.yml) | [Hourly VM backup](guides/01-hourly-vm-backup.md) |
| Pull a remote dataset down to local storage | [`configs/remote-to-local.yml`](configs/remote-to-local.yml) | — |
| Mirror a whole dataset subtree (recursive) | [`configs/recursive-pool.yml`](configs/recursive-pool.yml) | [Whole-pool mirror](guides/03-whole-pool-mirror.md) |
| Several jobs in one config | [`configs/multi-job.yml`](configs/multi-job.yml) | — |
| Offsite over a flaky link (resume/retry) | [`configs/offsite-resume.yml`](configs/offsite-resume.yml) | [Offsite over a flaky link](guides/02-offsite-over-flaky-link.md) |

## Real-world example

[`configs/monibeast.yml`](configs/monibeast.yml) is a full production config
migrated from a `zxfer` + `zfs-auto-snapshot` setup: a 25-job local/remote
backup hub running 3 jobs in parallel (`concurrency: 3`), mixing recursive
local mirrors with remote OS/data pulls over non-default SSH ports. Its header
documents the migration decisions (snapshot ownership, fail-fast on offline
hosts, `force` on first overwrite). Useful as a reference for scaling beyond a
handful of jobs.

## Trying an example

Point `-c` at any config without touching your real one:

```sh
zfsreplicate -c examples/configs/local-to-remote.yml list
zfsreplicate -n -c examples/configs/local-to-remote.yml sync   # dry run
```

Adjust hosts, datasets, and `identity` paths to match your environment before a
real `sync`.
