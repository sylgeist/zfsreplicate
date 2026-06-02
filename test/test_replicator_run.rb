# test/test_replicator_run.rb
# Integration tests for the full Replicator#run orchestration, using a recording
# fake at the executor (I/O) boundary so no live ZFS is needed.
require 'test_helper'
require 'zfsreplicate/snapshot'
require 'zfsreplicate/executor'
require 'zfsreplicate/dataset'
require 'zfsreplicate/replicator'
require 'zfsreplicate/config'

class RecordingExecutor
  attr_reader :commands, :pipelines

  # responses: array of [Regexp, String | :raise]
  def initialize(responses = [])
    @responses = responses
    @commands = []
    @pipelines = []
  end

  def local?
    true
  end

  def ssh_prefix
    nil
  end

  def run(cmd)
    @commands << cmd
    _, value = @responses.find { |rx, _| rx =~ cmd }
    raise ZFSReplicate::ExecutorError, "command failed: #{cmd}" if value == :raise
    value || ""
  end

  def run_pipeline(src_cmd, dst_cmd)
    @pipelines << [src_cmd, dst_cmd]
    ""
  end
end

def endpoint(dataset)
  ZFSReplicate::EndpointConfig.new(nil, 'root', dataset, 22, nil)
end

def replication(force: false, keep: 7, recursive: false)
  ZFSReplicate::ReplicationConfig.new(
    'job', endpoint('tank/vms'), endpoint('backup/vms'),
    recursive, keep, 'zfsreplicate', force
  )
end

class TestReplicatorRun < Minitest::Test
  SRC_THREE = <<~OUT
    tank/vms@zfsreplicate-20260401-000000
    tank/vms@zfsreplicate-20260410-000000
    tank/vms@zfsreplicate-20260420-000000
  OUT

  DST_TWO = <<~OUT
    backup/vms@zfsreplicate-20260401-000000
    backup/vms@zfsreplicate-20260410-000000
  OUT

  def build(src_resp, dst_resp, cfg)
    @src = RecordingExecutor.new(src_resp)
    @dst = RecordingExecutor.new(dst_resp)
    ZFSReplicate::Replicator.new(cfg, src_executor: @src, dst_executor: @dst)
  end

  def test_creates_source_snapshot
    rep = build(
      [[/zfs list -t snapshot/, SRC_THREE]],
      [[/zfs list -t snapshot/, ""], [/zfs list -H -o name/, :raise]],
      replication
    )
    rep.run
    assert @src.commands.any? { |c| c =~ /\Azfs snapshot tank\/vms@zfsreplicate-\d{8}-\d{6}\z/ },
           "expected a zfs snapshot command, got #{@src.commands.inspect}"
  end

  def test_full_send_to_fresh_destination
    rep = build(
      [[/zfs list -t snapshot/, SRC_THREE]],
      [[/zfs list -t snapshot/, ""], [/zfs list -H -o name/, :raise]],
      replication
    )
    rep.run
    assert_equal 1, @src.pipelines.length
    send_cmd, recv_cmd = @src.pipelines.first
    assert_match /\Azfs send tank\/vms@zfsreplicate-20260420-000000\z/, send_cmd
    assert_match /zfs recv -F backup\/vms/, recv_cmd
  end

  def test_incremental_send_when_common_exists
    rep = build(
      [[/zfs list -t snapshot/, SRC_THREE]],
      [[/zfs list -t snapshot/, DST_TWO]],
      replication
    )
    rep.run
    send_cmd, = @src.pipelines.first
    assert_equal(
      'zfs send -I tank/vms@zfsreplicate-20260410-000000 tank/vms@zfsreplicate-20260420-000000',
      send_cmd
    )
  end

  def test_aborts_on_existing_destination_without_common
    rep = build(
      [[/zfs list -t snapshot/, SRC_THREE]],
      # destination has no managed snapshots but the dataset exists (list -H succeeds)
      [[/zfs list -t snapshot/, ""], [/zfs list -H -o name/, "backup/vms\n"]],
      replication(force: false)
    )
    err = assert_raises(ZFSReplicate::ExecutorError) { rep.run }
    assert_match /refusing full send/, err.message
    assert_empty @src.pipelines, "must not send when guard trips"
  end

  def test_force_allows_send_to_existing_destination
    rep = build(
      [[/zfs list -t snapshot/, SRC_THREE]],
      [[/zfs list -t snapshot/, ""], [/zfs list -H -o name/, "backup/vms\n"]],
      replication(force: true)
    )
    rep.run
    assert_equal 1, @src.pipelines.length
  end

  def test_prunes_old_snapshots_on_both_sides
    rep = build(
      [[/zfs list -t snapshot/, SRC_THREE]],
      [[/zfs list -t snapshot/, DST_TWO]],
      replication(keep: 1)
    )
    rep.run
    # source had 3 managed, keep 1 => destroy 2 oldest
    src_destroys = @src.commands.grep(/zfs destroy/)
    assert_equal 2, src_destroys.length
    assert(src_destroys.any? { |c| c.include?('zfsreplicate-20260401-000000') })
    # destination had 2 managed, keep 1 => destroy 1 oldest
    dst_destroys = @dst.commands.grep(/zfs destroy/)
    assert_equal 1, dst_destroys.length
  end
end
