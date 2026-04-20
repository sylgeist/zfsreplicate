# test/test_dataset.rb
require 'test_helper'
require 'zfsreplicate/snapshot'
require 'zfsreplicate/dataset'

ZFS_LIST_OUTPUT = <<~OUTPUT
  tank/vms@zfsreplicate-20260401-000000
  tank/vms@zfsreplicate-20260410-000000
  tank/vms@manual
  tank/vms@zfsreplicate-20260420-000000
OUTPUT

class TestDataset < Minitest::Test
  def setup
    @exec = Minitest::Mock.new
    @ds = ZFSReplicate::Dataset.new('tank/vms', executor: @exec)
  end

  def test_snapshots_returns_parsed_list
    @exec.expect(:run, ZFS_LIST_OUTPUT, [String])
    snaps = @ds.snapshots
    assert_equal 4, snaps.length
    assert_instance_of ZFSReplicate::Snapshot, snaps.first
    @exec.verify
  end

  def test_snapshots_are_sorted_oldest_first
    @exec.expect(:run, ZFS_LIST_OUTPUT, [String])
    snaps = @ds.snapshots
    assert snaps[0].tag == 'manual'
    assert snaps[1].tag == 'zfsreplicate-20260401-000000'
    assert snaps[2].tag == 'zfsreplicate-20260410-000000'
    assert snaps[3].tag == 'zfsreplicate-20260420-000000'
    @exec.verify
  end

  def test_managed_snapshots_filters_by_prefix
    @exec.expect(:run, ZFS_LIST_OUTPUT, [String])
    snaps = @ds.managed_snapshots(prefix: 'zfsreplicate')
    assert_equal 3, snaps.length
    assert snaps.none? { |s| s.tag == 'manual' }
    @exec.verify
  end

  def test_latest_snapshot_returns_most_recent
    @exec.expect(:run, ZFS_LIST_OUTPUT, [String])
    latest = @ds.latest_snapshot(prefix: 'zfsreplicate')
    assert_equal 'zfsreplicate-20260420-000000', latest.tag
    @exec.verify
  end

  def test_snapshots_returns_empty_when_none
    @exec.expect(:run, '', [String])
    assert_empty @ds.snapshots
    @exec.verify
  end
end
