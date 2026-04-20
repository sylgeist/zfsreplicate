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
  attr_accessor :response, :calls

  def initialize(response = nil)
    @response = response
    @calls = []
  end

  def run(cmd)
    @calls << cmd
    @response
  end
end

class TestDataset < Minitest::Test
  def setup
    @exec = MockExecutor.new
    @ds = ZFSReplicate::Dataset.new('tank/vms', executor: @exec)
  end

  def test_snapshots_returns_parsed_list
    @exec.response = ZFS_LIST_OUTPUT
    snaps = @ds.snapshots
    assert_equal 4, snaps.length
    assert_instance_of ZFSReplicate::Snapshot, snaps.first
  end

  def test_snapshots_are_sorted_oldest_first
    @exec.response = ZFS_LIST_OUTPUT
    snaps = @ds.snapshots
    # Verify they're sorted by time (with nil times sorting first)
    assert snaps[0].tag == 'manual'
    assert snaps[1].tag == 'zfsreplicate-20260401-000000'
    assert snaps[2].tag == 'zfsreplicate-20260410-000000'
    assert snaps[3].tag == 'zfsreplicate-20260420-000000'
  end

  def test_managed_snapshots_filters_by_prefix
    @exec.response = ZFS_LIST_OUTPUT
    snaps = @ds.managed_snapshots(prefix: 'zfsreplicate')
    assert_equal 3, snaps.length
    assert snaps.none? { |s| s.tag == 'manual' }
  end

  def test_latest_snapshot_returns_most_recent
    @exec.response = ZFS_LIST_OUTPUT
    latest = @ds.latest_snapshot(prefix: 'zfsreplicate')
    assert_equal 'zfsreplicate-20260420-000000', latest.tag
  end

  def test_snapshots_returns_empty_when_none
    @exec.response = ''
    assert_empty @ds.snapshots
  end
end
