# Usage Examples — Design

Date: 2026-07-05

## Goal

Add copy-paste-ready, real-world usage examples for `zfsreplicate` to the repo.
The main `README.md` already documents every field and command inline; this adds
complete *scenarios* — annotated config files plus narrative walkthroughs — that a
new user can adapt directly.

## Housekeeping

The untracked `examples/` directory currently holds 4 internal concurrency
sandbox scripts (`concurrency_sandbox.rb`, `condition_variable_sandbox.rb`,
`config_reload_sandbox.rb`, `open3_sandbox.rb`) — prototypes for the not-yet-merged
parallel-execution work. Move them to `docs/dev/sandboxes/` and commit, freeing
`examples/` for user-facing content and preserving the prototypes for later Spec 2 work.

## Structure

```
examples/
  README.md              # scenario index (table: scenario -> config -> guide)
  configs/
    local-to-remote.yml  # push a local dataset to a remote host
    remote-to-local.yml  # pull a remote dataset home
    recursive-pool.yml   # recursive: true, whole pool subtree
    multi-job.yml        # several replications, run in one `sync`
    offsite-resume.yml   # flaky WAN link: resume + max_retries/retry_delay tuned
  guides/
    01-hourly-vm-backup.md         # local->remote: SSH keys, first sync, cron, verify
    02-offsite-over-flaky-link.md  # resume/retry behavior, interrupt & resume
    03-whole-pool-mirror.md        # recursive backup + pruning / keep_snapshots
```

## Content principles

- **Only fields that exist today**, validated against `lib/zfsreplicate/config.rb`:
  `name`, `source`/`destination` `{host,user,dataset,port,identity}`, `recursive`,
  `keep_snapshots`, `snapshot_prefix`, `force`, `resume`, `max_retries`,
  `retry_delay`. **No parallel/concurrency fields** — that feature is not merged.
- Each config is heavily commented.
- Each guide follows: setup → SSH key check → config → dry-run → real sync → cron → verify.
- Commands match the real CLI (`zfsreplicate -n sync`, `-v sync <name>`, `list`, `-c <file>`).
- `examples/README.md` maps scenario → config → guide and links back to the main README.

## Guard test

Add `test/test_examples.rb` (wired into `test/run_all.rb`) asserting that every
`examples/configs/*.yml` loads without error via `ZFSReplicate::Config.load`. This
guards the examples against config-schema drift. ~10 lines.

## Out of scope

- Any concurrency/parallel example (feature unmerged).
- Changes to the main README beyond a link to `examples/`.
