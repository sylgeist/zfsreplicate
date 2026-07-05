# Offsite backup over a flaky link

Send a large dataset offsite across an unreliable WAN, surviving dropped
connections without restarting the transfer.

Config: [`../configs/offsite-resume.yml`](../configs/offsite-resume.yml)

## How resume works

By default each transfer uses `zfs recv -s`, so an interrupted
`zfs send | zfs recv` can continue instead of restarting:

- On failure, the transfer is retried up to `max_retries` times with exponential
  backoff (`retry_delay`, doubling each attempt). Each retry resumes from the
  destination's `receive_resume_token` rather than resending from scratch.
- If the whole run still fails, the partial state is left on the destination.
  The **next** `sync` detects the leftover token and continues it before doing
  anything else.

## Tuning for a bad link

The example config widens the defaults so a big initial send tolerates several
drops:

```yaml
resume: true      # default; uses zfs recv -s
max_retries: 6    # up to 7 attempts per transfer
retry_delay: 10   # backoff base: 10s, 20s, 40s, 80s, ...
```

## First send

```sh
zfsreplicate -v -c examples/configs/offsite-resume.yml sync offsite-archive
```

If the link drops mid-transfer you'll see retry/backoff messages; when retries
are exhausted the run exits non-zero but leaves resumable state behind.

## Resuming after a total failure

Just run `sync` again — the leftover `receive_resume_token` is picked up
automatically:

```sh
zfsreplicate -v -c examples/configs/offsite-resume.yml sync offsite-archive
```

## Discarding a stuck partial receive

To throw away a partial receive and force a fresh send, clear the token on the
destination first:

```sh
ssh -p 2222 zfsrepl@offsite.example.com zfs recv -A pool/archive
```

To disable resume entirely (single attempt, `zfs recv -F`, no retries), set
`resume: false` on the job.
