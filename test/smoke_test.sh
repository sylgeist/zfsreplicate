#!/bin/sh
# Live end-to-end smoke test against real ZFS, using disposable file-backed
# pools. Complements the unit suite: every path here (bootstrap, incremental,
# recursive coverage, pruning, guard, resume) depends on real zfs exit codes
# and stream semantics that the pure-double tests cannot model.
#
# Requirements: root, zfs/zpool, ~1 GB free in $TMPDIR (or /tmp).
# The resume scenario additionally needs mbuffer and is skipped without it.
#
# Usage: sudo sh test/smoke_test.sh
set -u

cd "$(dirname "$0")/.." || exit 2
ZR="ruby -Ilib bin/zfsreplicate"
PREFIX=zrsmoke
WORK="${TMPDIR:-/tmp}/zrsmoke.$$"
SRC_POOL="zrsmokesrc$$"
DST_POOL="zrsmokedst$$"
PASS=0
FAIL=0
SKIP=0

say()  { printf '%s\n' "== $*"; }
pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$*"; }
skip() { SKIP=$((SKIP + 1)); printf 'SKIP: %s\n' "$*"; }

cleanup() {
  zpool destroy -f "$SRC_POOL" 2>/dev/null
  zpool destroy -f "$DST_POOL" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

[ "$(id -u)" = 0 ] || { echo "must run as root (zfs operations)"; exit 2; }
command -v zpool >/dev/null 2>&1 || { echo "zpool not found"; exit 2; }

mkdir -p "$WORK/mnt"
truncate -s 512m "$WORK/src.img" "$WORK/dst.img" || exit 2
zpool create -R "$WORK/mnt" -O atime=off "$SRC_POOL" "$WORK/src.img" || exit 2
zpool create -R "$WORK/mnt" -O atime=off "$DST_POOL" "$WORK/dst.img" || exit 2

zfs create "$SRC_POOL/data"
zfs create "$SRC_POOL/data/child"
dd if=/dev/urandom of="$WORK/mnt/$SRC_POOL/data/a.bin" bs=1m count=4 2>/dev/null
dd if=/dev/urandom of="$WORK/mnt/$SRC_POOL/data/child/c.bin" bs=1m count=2 2>/dev/null

DST_DS="$DST_POOL/backup"

write_config() { # $1=file  $2..=extra per-job lines
  f=$1; shift
  cat > "$f" <<EOF
lock_dir: $WORK/locks
replications:
  - name: smoke
    source:      { dataset: $SRC_POOL/data }
    destination: { dataset: $DST_DS }
    snapshot_prefix: $PREFIX
    recursive: true
    keep_snapshots: 2
EOF
  for line in "$@"; do printf '    %s\n' "$line" >> "$f"; done
}

write_config "$WORK/main.yml"
write_config "$WORK/force.yml" "force: true"

snap_count() { zfs list -t snapshot -d 1 -H -o name "$1" 2>/dev/null | grep -c "@$PREFIX-"; }
latest_tag() { zfs list -t snapshot -d 1 -H -o name -s creation "$1" | grep "@$PREFIX-" | tail -1 | cut -d@ -f2; }

# --- S1: bootstrap — fresh full send to a nonexistent destination -----------
say "S1: bootstrap full send (destination does not exist)"
if $ZR -c "$WORK/main.yml" sync >"$WORK/s1.log" 2>&1; then
  if [ "$(snap_count "$DST_DS")" = 1 ] && [ "$(snap_count "$DST_DS/child")" = 1 ]; then
    pass "bootstrap created destination and recursive child with 1 snapshot each"
  else
    fail "bootstrap ran but snapshots missing (dst=$(snap_count "$DST_DS") child=$(snap_count "$DST_DS/child"))"
  fi
else
  fail "bootstrap sync exited non-zero: $(tail -3 "$WORK/s1.log")"
fi

# --- S2: incremental with data integrity ------------------------------------
say "S2: incremental send"
dd if=/dev/urandom of="$WORK/mnt/$SRC_POOL/data/b.bin" bs=1m count=4 2>/dev/null
sleep 1 # snapshot names have 1s resolution
if $ZR -c "$WORK/main.yml" sync >"$WORK/s2.log" 2>&1; then
  zfs mount "$DST_DS" 2>/dev/null
  src_sum=$(cksum < "$WORK/mnt/$SRC_POOL/data/b.bin")
  dst_sum=$(cksum < "$WORK/mnt/$DST_DS/b.bin" 2>/dev/null)
  if [ "$src_sum" = "$dst_sum" ] && [ "$(latest_tag "$DST_DS")" = "$(latest_tag "$SRC_POOL/data")" ]; then
    pass "incremental replicated data intact; destination at latest"
  else
    fail "incremental mismatch (sum: $src_sum vs $dst_sum; tags: $(latest_tag "$SRC_POOL/data") vs $(latest_tag "$DST_DS"))"
  fi
else
  fail "incremental sync exited non-zero: $(tail -3 "$WORK/s2.log")"
fi

# --- S3: retention prunes both sides, including recursive children ----------
say "S3: retention (keep_snapshots: 2)"
sleep 1
if $ZR -c "$WORK/main.yml" sync >"$WORK/s3.log" 2>&1; then
  s=$(snap_count "$SRC_POOL/data"); d=$(snap_count "$DST_DS"); c=$(snap_count "$DST_DS/child")
  if [ "$s" = 2 ] && [ "$d" = 2 ] && [ "$c" = 2 ]; then
    pass "both sides pruned to 2 snapshots, children included"
  else
    fail "retention counts wrong (src=$s dst=$d child=$c, expected 2 each)"
  fi
else
  fail "third sync exited non-zero: $(tail -3 "$WORK/s3.log")"
fi

# --- S4: full-send guard refuses to overwrite without force -----------------
say "S4: guard on existing destination with no common snapshot"
zfs list -t snapshot -d 1 -H -o name "$DST_DS" | grep "@$PREFIX-" | while read -r s; do
  zfs destroy -r "$s"
done
sleep 1 # snapshot names have 1s resolution
if $ZR -c "$WORK/main.yml" sync >"$WORK/s4.log" 2>&1; then
  fail "sync succeeded but should have tripped the full-send guard"
else
  if grep -q "refusing full send" "$WORK/s4.log"; then
    pass "guard refused unforced full send onto existing destination"
  else
    fail "sync failed for the wrong reason: $(tail -3 "$WORK/s4.log")"
  fi
fi

# --- S5: force overrides the guard ------------------------------------------
say "S5: force: true permits the overwrite"
sleep 1
if $ZR -c "$WORK/force.yml" sync >"$WORK/s5.log" 2>&1 &&
   [ "$(latest_tag "$DST_DS")" = "$(latest_tag "$SRC_POOL/data")" ]; then
  pass "forced full send rebuilt the destination"
else
  fail "forced sync failed: $(tail -3 "$WORK/s5.log")"
fi

# --- S6: interrupted transfer leaves a token; next run resumes it -----------
say "S6: interrupt via job timeout, then resume"
if command -v mbuffer >/dev/null 2>&1; then
  dd if=/dev/urandom of="$WORK/mnt/$SRC_POOL/data/big.bin" bs=1m count=64 2>/dev/null
  write_config "$WORK/slow.yml" "bwlimit: 4m" "timeout: 4" "max_retries: 0"
  sleep 1
  $ZR -c "$WORK/slow.yml" sync >"$WORK/s6a.log" 2>&1 # expected to fail: killed at 4s
  token=$(zfs get -H -o value receive_resume_token "$DST_DS")
  if [ -n "$token" ] && [ "$token" != "-" ]; then
    if $ZR -c "$WORK/main.yml" sync >"$WORK/s6b.log" 2>&1 &&
       [ "$(zfs get -H -o value receive_resume_token "$DST_DS")" = "-" ] &&
       [ "$(latest_tag "$DST_DS")" = "$(latest_tag "$SRC_POOL/data")" ]; then
      pass "interrupted transfer resumed to completion, token cleared"
    else
      fail "resume run did not complete cleanly: $(tail -3 "$WORK/s6b.log")"
    fi
  else
    fail "timeout kill left no resume token (transfer too fast? see $WORK/s6a.log)"
  fi
else
  skip "mbuffer not installed; cannot slow the stream enough to interrupt it"
fi

# --- S7: config hygiene (no pools involved) ---------------------------------
say "S7: config validation UX"
write_config "$WORK/typo.yml" "keep_snapshot: 3"
$ZR -c "$WORK/typo.yml" list >"$WORK/s7a.log" 2>&1
if grep -q "keep_snapshot" "$WORK/s7a.log"; then
  pass "unknown key warned about at startup"
else
  fail "no warning for typo'd config key"
fi
{ cat "$WORK/main.yml"; sed 1,2d "$WORK/main.yml"; } > "$WORK/dup.yml"
$ZR -c "$WORK/dup.yml" list >"$WORK/s7b.log" 2>&1
if [ $? = 2 ] && grep -q "Duplicate" "$WORK/s7b.log"; then
  pass "duplicate job names rejected with exit 2"
else
  fail "duplicate job names not rejected (see $WORK/s7b.log)"
fi

echo
echo "Smoke test: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" = 0 ]
