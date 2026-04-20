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
    cmd = Replicator.send_command(latest: latest, common: nil, recursive: false)
    assert_equal 'zfs send tank/vms@zfsreplicate-20260420-000000', cmd
  end

  def test_incremental_send_command
    common = make_snap('tank/vms', 'zfsreplicate-20260410-000000')
    latest = make_snap('tank/vms', 'zfsreplicate-20260420-000000')
    cmd = Replicator.send_command(latest: latest, common: common, recursive: false)
    assert_equal(
      'zfs send -I tank/vms@zfsreplicate-20260410-000000 tank/vms@zfsreplicate-20260420-000000',
      cmd
    )
  end

  def test_recursive_flag
    latest = make_snap('tank/vms', 'zfsreplicate-20260420-000000')
    cmd = Replicator.send_command(latest: latest, common: nil, recursive: true)
    assert_includes cmd, 'zfs send -R'
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
