# test/test_replicator.rb
require 'test_helper'
require 'zfsreplicate/snapshot'
require 'zfsreplicate/executor'
require 'zfsreplicate/dataset'
require 'zfsreplicate/replicator'

def make_snap(dataset, tag)
  ZFSReplicate::Snapshot.parse("#{dataset}@#{tag}")
end

class TestReplicatorCommonSnapshot < Minitest::Test
  include ZFSReplicate

  def test_finds_common_ancestor_by_tag
    src = [
      make_snap('tank/vms', 'zfsreplicate-20260401-000000'),
      make_snap('tank/vms', 'zfsreplicate-20260410-000000'),
      make_snap('tank/vms', 'zfsreplicate-20260420-000000'),
    ]
    dst = [
      make_snap('backup/vms', 'zfsreplicate-20260401-000000'),
      make_snap('backup/vms', 'zfsreplicate-20260410-000000'),
    ]
    common = Replicator.common_snapshot(src, dst)
    assert_equal 'zfsreplicate-20260410-000000', common.tag
  end

  def test_returns_nil_when_no_common
    src = [make_snap('tank/vms', 'zfsreplicate-20260420-000000')]
    dst = [make_snap('backup/vms', 'zfsreplicate-20260401-000000')]
    assert_nil Replicator.common_snapshot(src, dst)
  end

  def test_returns_nil_when_destination_empty
    src = [make_snap('tank/vms', 'zfsreplicate-20260420-000000')]
    assert_nil Replicator.common_snapshot(src, [])
  end
end

class TestReplicatorSendCommand < Minitest::Test
  include ZFSReplicate

  def test_full_send_command
    latest = make_snap('tank/vms', 'zfsreplicate-20260420-000000')
    cmd = Replicator.send_command(latest: latest, common: nil, recursive: false, compressed: false)
    assert_equal 'zfs send tank/vms@zfsreplicate-20260420-000000', cmd
  end

  def test_incremental_send_command
    common = make_snap('tank/vms', 'zfsreplicate-20260410-000000')
    latest = make_snap('tank/vms', 'zfsreplicate-20260420-000000')
    cmd = Replicator.send_command(latest: latest, common: common, recursive: false, compressed: false)
    assert_equal(
      'zfs send -I tank/vms@zfsreplicate-20260410-000000 tank/vms@zfsreplicate-20260420-000000',
      cmd
    )
  end

  def test_recursive_flag
    latest = make_snap('tank/vms', 'zfsreplicate-20260420-000000')
    cmd = Replicator.send_command(latest: latest, common: nil, recursive: true, compressed: false)
    assert_includes cmd, 'zfs send -R'
  end

  def test_compressed_full_send_adds_c
    latest = make_snap('tank/vms', 'zfsreplicate-20260420-000000')
    cmd = Replicator.send_command(latest: latest, common: nil, recursive: false, compressed: true)
    assert_equal 'zfs send -c tank/vms@zfsreplicate-20260420-000000', cmd
  end

  def test_compressed_incremental_send_adds_c
    common = make_snap('tank/vms', 'zfsreplicate-20260410-000000')
    latest = make_snap('tank/vms', 'zfsreplicate-20260420-000000')
    cmd = Replicator.send_command(latest: latest, common: common, recursive: false, compressed: true)
    assert_includes cmd, 'zfs send -c -I '
  end
end

class TestReplicatorResumeCommands < Minitest::Test
  include ZFSReplicate

  def test_resume_send_command
    assert_equal 'zfs send -t 1-abc', Replicator.resume_send_command(token: '1-abc')
  end

  def test_recv_command_fresh_resumable
    assert_equal 'zfs recv -F -s backup/vms',
                 Replicator.recv_command(dataset: 'backup/vms', fresh: true, resumable: true)
  end

  def test_recv_command_fresh_not_resumable
    assert_equal 'zfs recv -F backup/vms',
                 Replicator.recv_command(dataset: 'backup/vms', fresh: true, resumable: false)
  end

  def test_recv_command_resume_continuation
    assert_equal 'zfs recv -s backup/vms',
                 Replicator.recv_command(dataset: 'backup/vms', fresh: false, resumable: true)
  end
end

class TestReplicatorFullSendGuard < Minitest::Test
  include ZFSReplicate

  def test_allows_incremental_regardless_of_destination
    common = make_snap('tank/vms', 'zfsreplicate-20260410-000000')
    # Should not raise even though destination exists.
    Replicator.guard_full_send!(destination: 'backup/vms', common: common,
                                destination_exists: true, force: false)
  end

  def test_allows_full_send_to_fresh_destination
    Replicator.guard_full_send!(destination: 'backup/vms', common: nil,
                                destination_exists: false, force: false)
  end

  def test_rejects_full_send_to_existing_destination
    err = assert_raises(ExecutorError) do
      Replicator.guard_full_send!(destination: 'backup/vms', common: nil,
                                  destination_exists: true, force: false)
    end
    assert_match /backup\/vms/, err.message
    assert_match /force/, err.message
  end

  def test_force_overrides_existing_destination
    Replicator.guard_full_send!(destination: 'backup/vms', common: nil,
                                destination_exists: true, force: true)
  end
end

class TestReplicatorPruning < Minitest::Test
  include ZFSReplicate

  def test_snapshots_to_prune_keeps_most_recent
    snaps = (1..10).map { |i| make_snap('tank/vms', "zfsreplicate-2026040#{i % 10 + 1}-000000") }
    to_prune = Replicator.snapshots_to_prune(snaps, keep: 3)
    assert_equal 7, to_prune.length
    kept_tags = (snaps - to_prune).map(&:tag)
    assert_includes kept_tags, snaps.max.tag
  end

  def test_no_pruning_when_under_limit
    snaps = [make_snap('tank/vms', 'zfsreplicate-20260420-000000')]
    assert_empty Replicator.snapshots_to_prune(snaps, keep: 7)
  end
end

class TestReplicatorTransport < Minitest::Test
  include ZFSReplicate

  # Executor double: run() succeeds or fails based on `found`.
  FakeExec = Struct.new(:found) do
    def run(_cmd)
      raise ZFSReplicate::ExecutorError, 'command failed' unless found
      "/usr/local/bin/mbuffer\n"
    end
  end

  def test_transfer_stages_without_bwlimit
    stages = Replicator.transfer_stages(send_cmd: 'zfs send x', recv_cmd: 'zfs recv y', bwlimit: nil)
    assert_equal ['zfs send x', 'zfs recv y'], stages
  end

  def test_transfer_stages_with_bwlimit_inserts_mbuffer
    stages = Replicator.transfer_stages(send_cmd: 'zfs send x', recv_cmd: 'zfs recv y', bwlimit: '50m')
    assert_equal ['zfs send x', 'mbuffer -q -R 50m', 'zfs recv y'], stages
  end

  def test_ensure_mbuffer_passes_when_present
    # Should not raise.
    assert_nil Replicator.ensure_mbuffer!(FakeExec.new(true))
  end

  def test_ensure_mbuffer_raises_when_missing
    err = assert_raises(ZFSReplicate::ExecutorError) do
      Replicator.ensure_mbuffer!(FakeExec.new(false))
    end
    assert_match(/mbuffer/, err.message)
  end
end
