# test/test_snapshot.rb
require 'test_helper'
require 'zfsreplicate/snapshot'

class TestSnapshot < Minitest::Test
  def test_generate_name_includes_prefix_and_timestamp
    t = Time.utc(2026, 4, 20, 15, 30, 0)
    name = ZFSReplicate::Snapshot.generate_name('tank/vms', prefix: 'zfsreplicate', time: t)
    assert_equal 'tank/vms@zfsreplicate-20260420-153000', name
  end

  def test_parse_full_snapshot_name
    snap = ZFSReplicate::Snapshot.parse('tank/vms@zfsreplicate-20260420-153000')
    assert_equal 'tank/vms', snap.dataset
    assert_equal 'zfsreplicate-20260420-153000', snap.tag
    assert_equal Time.utc(2026, 4, 20, 15, 30, 0), snap.time
    assert_equal 'zfsreplicate', snap.prefix
  end

  def test_parse_returns_nil_for_unrecognized_tag
    snap = ZFSReplicate::Snapshot.parse('tank/vms@manual-snap')
    assert_equal 'tank/vms', snap.dataset
    assert_equal 'manual-snap', snap.tag
    assert_nil snap.time
    assert_nil snap.prefix
  end

  def test_generate_uses_utc
    t = Time.new(2026, 4, 20, 23, 59, 59, '+05:00')
    name = ZFSReplicate::Snapshot.generate_name('data', prefix: 'rep', time: t)
    # Stored as UTC
    assert_match /rep-20260420-185959/, name
  end

  def test_snapshots_sortable_by_time
    a = ZFSReplicate::Snapshot.parse('tank@zfsreplicate-20260101-000000')
    b = ZFSReplicate::Snapshot.parse('tank@zfsreplicate-20260201-000000')
    assert a < b
  end
end
