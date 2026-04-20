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

class MockExecutor
  attr_reader :last_cmd

  def initialize(response)
    @response = response
    @last_cmd = nil
  end

  def run(cmd)
    @last_cmd = cmd
    @response
  end
end

class TestDataset < Minitest::Test
  def setup
    @exec = MockExecutor.new(ZFS_LIST_OUTPUT)
    @ds = ZFSReplicate::Dataset.new('tank/vms', executor: @exec)
  end

  def test_snapshots_returns_parsed_list
    snaps = @ds.snapshots
    assert_equal 4, snaps.length
    assert_instance_of ZFSReplicate::Snapshot, snaps.first
    assert_match /zfs list -t snapshot/, @exec.last_cmd
  end

  def test_snapshots_are_sorted_oldest_first
    snaps = @ds.snapshots
    assert_equal 'manual', snaps[0].tag
    assert_equal 'zfsreplicate-20260401-000000', snaps[1].tag
    assert_equal 'zfsreplicate-20260410-000000', snaps[2].tag
    assert_equal 'zfsreplicate-20260420-000000', snaps[3].tag
  end

  def test_managed_snapshots_filters_by_prefix
    snaps = @ds.managed_snapshots(prefix: 'zfsreplicate')
    assert_equal 3, snaps.length
    assert snaps.none? { |s| s.tag == 'manual' }
  end

  def test_latest_snapshot_returns_most_recent
    latest = @ds.latest_snapshot(prefix: 'zfsreplicate')
    assert_equal 'zfsreplicate-20260420-000000', latest.tag
  end

  def test_snapshots_returns_empty_when_none
    exec = MockExecutor.new('')
    ds = ZFSReplicate::Dataset.new('tank/vms', executor: exec)
    assert_empty ds.snapshots
  end
end
