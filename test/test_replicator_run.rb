# test/test_replicator_run.rb
# Integration tests for the full Replicator#run orchestration, using a recording
# fake at the executor (I/O) boundary so no live ZFS is needed.
require 'test_helper'
require 'stringio'
require 'zfsreplicate/snapshot'
require 'zfsreplicate/executor'
require 'zfsreplicate/dataset'
require 'zfsreplicate/replicator'
require 'zfsreplicate/config'

class RecordingExecutor
  attr_reader :commands, :pipelines, :pipeline_timeouts, :events

  # responses: array of [Regexp, String | :raise | Proc | Array<String|:raise>]
  #   - an Array value is consumed one element per matching call; the last
  #     element sticks once reached.
  #   - a Proc is called per matching call and may return a String or :raise,
  #     letting a response depend on test state (e.g. "after the transfer ran").
  # pipeline_failures: the first N run_pipeline calls raise ExecutorError,
  # with pipeline_error as the message.
  def initialize(responses = [], pipeline_failures: 0,
                 pipeline_error: "pipeline failed (simulated)")
    @responses = responses
    @pipeline_failures = pipeline_failures
    @pipeline_error = pipeline_error
    @commands = []
    @pipelines = []
    @pipeline_timeouts = []
    @events = []
  end

  def local?
    true
  end

  def ssh_prefix
    nil
  end

  def run(cmd)
    @commands << cmd
    @events << [:run, cmd]
    pair = @responses.find { |rx, _| rx =~ cmd }
    return "" unless pair
    value = pair[1]
    value = value.call if value.is_a?(Proc)
    value = (value.length > 1 ? value.shift : value.first) if value.is_a?(Array)
    # :raise models the missing-dataset failure, phrased the way zfs phrases it.
    if value == :raise
      raise ZFSReplicate::ExecutorError,
            "zfs exited with status 1: cannot open: dataset does not exist (#{cmd})"
    end
    value || ""
  end

  def run_pipeline(*cmds, timeout: nil)
    @pipelines << cmds
    @pipeline_timeouts << timeout
    @events << [:pipeline, cmds.first]
    if @pipelines.length <= @pipeline_failures
      raise ZFSReplicate::ExecutorError, @pipeline_error
    end
    ""
  end
end

def endpoint(dataset)
  ZFSReplicate::EndpointConfig.new(nil, 'root', dataset, 22, nil)
end

def replication(force: false, keep: 7, recursive: false,
                resume: true, max_retries: 3, retry_delay: 5,
                compressed_send: false, bwlimit: nil, timeout: nil,
                raw_send: false, create_snapshot: true)
  ZFSReplicate::ReplicationConfig.new(
    'job', endpoint('tank/vms'), endpoint('backup/vms'),
    recursive, keep, 'zfsreplicate', force, resume, max_retries, retry_delay,
    compressed_send, bwlimit, timeout, true, raw_send, create_snapshot
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

  # What the destination lists after the incremental transfer lands.
  DST_THREE = DST_TWO + "backup/vms@zfsreplicate-20260420-000000\n"

  def build(src_resp, dst_resp, cfg, src_failures: 0)
    @delays = []
    @src = RecordingExecutor.new(src_resp, pipeline_failures: src_failures)
    @dst = RecordingExecutor.new(dst_resp)
    ZFSReplicate::Replicator.new(cfg, src_executor: @src, dst_executor: @dst,
                                 sleeper: ->(s) { @delays << s })
  end

  def test_creates_source_snapshot
    rep = build(
      [[/zfs list -t snapshot/, SRC_THREE]],
      [[/zfs list -t snapshot/, DST_AFTER_FULL], [/zfs list -H -o name/, :raise]],
      replication
    )
    rep.run
    assert @src.commands.any? { |c| c =~ /\Azfs snapshot tank\/vms@zfsreplicate-\d{8}-\d{6}\z/ },
           "expected a zfs snapshot command, got #{@src.commands.inspect}"
  end

  DST_AFTER_FULL = "backup/vms@zfsreplicate-20260420-000000\n"

  # Real `zfs list` exits non-zero for a dataset that does not exist yet, so a
  # first-ever sync must not list destination snapshots before the full send
  # creates the dataset.
  def test_full_send_bootstraps_missing_destination
    @delays = []
    @src = RecordingExecutor.new([[/zfs list -t snapshot/, SRC_THREE]])
    before_transfer = -> { @src.pipelines.empty? }
    @dst = RecordingExecutor.new([
      [/zfs list -t snapshot/, -> { before_transfer.call ? :raise : DST_AFTER_FULL }],
      [/zfs list -H -o name/, -> { before_transfer.call ? :raise : "backup/vms\n" }]
    ])
    rep = ZFSReplicate::Replicator.new(replication, src_executor: @src,
                                       dst_executor: @dst,
                                       sleeper: ->(s) { @delays << s })
    rep.run
    assert_equal 1, @src.pipelines.length
    send_cmd, recv_cmd = @src.pipelines.first
    assert_match /\Azfs send tank\/vms@zfsreplicate-20260420-000000\z/, send_cmd
    assert_match /zfs recv -u -F -s -x mountpoint backup\/vms/, recv_cmd
  end

  def test_full_send_to_fresh_destination
    rep = build(
      [[/zfs list -t snapshot/, SRC_THREE]],
      [[/zfs list -t snapshot/, DST_AFTER_FULL], [/zfs list -H -o name/, :raise]],
      replication
    )
    rep.run
    assert_equal 1, @src.pipelines.length
    send_cmd, recv_cmd = @src.pipelines.first
    assert_match /\Azfs send tank\/vms@zfsreplicate-20260420-000000\z/, send_cmd
    assert_match /zfs recv -u -F -s -x mountpoint backup\/vms/, recv_cmd
  end

  def test_incremental_send_when_common_exists
    rep = build(
      [[/zfs list -t snapshot/, SRC_THREE]],
      [[/zfs list -t snapshot/, [DST_TWO, DST_THREE]]],
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
      [[/zfs list -t snapshot/, ["", DST_AFTER_FULL]],
       [/zfs list -H -o name/, "backup/vms\n"]],
      replication(force: true)
    )
    rep.run
    assert_equal 1, @src.pipelines.length
  end

  # A resumed transfer can complete only the interrupted snapshot of a
  # multi-snapshot -I package, leaving the destination behind `latest` while
  # the pipeline exits 0. Pruning at that point can destroy the destination's
  # only common base, so the run must verify and refuse to prune.
  def test_destination_behind_after_transfer_fails_before_pruning
    rep = build(
      [[/zfs list -t snapshot/, SRC_THREE]],
      [[/zfs list -t snapshot/, DST_TWO]], # still behind after "success"
      replication(keep: 1)
    )
    err = assert_raises(ZFSReplicate::ExecutorError) { rep.run }
    assert_match /behind/, err.message
    assert_empty @src.commands.grep(/zfs destroy/), "must not prune source"
    assert_empty @dst.commands.grep(/zfs destroy/), "must not prune destination"
  end

  def test_prunes_old_snapshots_on_both_sides
    rep = build(
      [[/zfs list -t snapshot/, SRC_THREE]],
      [[/zfs list -t snapshot/, [DST_TWO, DST_THREE]]],
      replication(keep: 1)
    )
    rep.run
    # source had 3 managed, keep 1 => destroy 2 oldest
    src_destroys = @src.commands.grep(/zfs destroy/)
    assert_equal 2, src_destroys.length
    assert(src_destroys.any? { |c| c.include?('zfsreplicate-20260401-000000') })
    # destination has 3 managed after the transfer, keep 1 => destroy 2 oldest
    dst_destroys = @dst.commands.grep(/zfs destroy/)
    assert_equal 2, dst_destroys.length
  end

  # Cascade jobs re-ship a replica whose snapshots are owned by the upstream
  # job (the source is a recv target; inbound recv -F destroys any snapshot
  # the upstream sender lacks). They must neither create nor prune on the
  # source — only ship the newest existing managed snapshot.
  def test_cascade_ships_existing_latest_without_touching_source
    rep = build(
      [[/zfs list -t snapshot/, SRC_THREE]],
      [[/zfs list -t snapshot/, [DST_TWO, DST_THREE]]],
      replication(create_snapshot: false, keep: 1)
    )
    rep.run
    assert_empty @src.commands.grep(/zfs snapshot/), "must not snapshot the source"
    assert_empty @src.commands.grep(/zfs destroy/), "must not prune the source"
    send_cmd, = @src.pipelines.first
    assert_equal(
      'zfs send -I tank/vms@zfsreplicate-20260410-000000 tank/vms@zfsreplicate-20260420-000000',
      send_cmd
    )
    refute_empty @dst.commands.grep(/zfs destroy/), "destination pruning still applies"
  end

  def test_cascade_with_no_managed_source_snapshots_fails_helpfully
    rep = build(
      [[/zfs list -t snapshot/, ""]],
      [[/zfs list -t snapshot/, ""]],
      replication(create_snapshot: false)
    )
    err = assert_raises(ZFSReplicate::ExecutorError) { rep.run }
    assert_match(/no managed snapshots/i, err.message)
    assert_match(/upstream/, err.message)
  end

  # `zfs send -R` only replicates children whose snapshots exist, so a
  # recursive job must snapshot (and prune) with -r or the "whole-pool mirror"
  # silently covers only the parent.
  def test_recursive_job_snapshots_and_destroys_recursively
    rep = build(
      [[/zfs list -t snapshot/, SRC_THREE]],
      [[/zfs list -t snapshot/, [DST_TWO, DST_THREE]]],
      replication(recursive: true, keep: 1)
    )
    rep.run
    assert @src.commands.any? { |c| c =~ /\Azfs snapshot -r tank\/vms@zfsreplicate-\d{8}-\d{6}\z/ },
           "expected recursive snapshot, got #{@src.commands.inspect}"
    src_destroys = @src.commands.grep(/zfs destroy/)
    refute_empty src_destroys
    assert src_destroys.all? { |c| c =~ /\Azfs destroy -r tank\/vms@/ },
           "expected recursive source destroys, got #{src_destroys.inspect}"
    dst_destroys = @dst.commands.grep(/zfs destroy/)
    refute_empty dst_destroys
    assert dst_destroys.all? { |c| c =~ /\Azfs destroy -r backup\/vms@/ },
           "expected recursive destination destroys, got #{dst_destroys.inspect}"
  end

  # When the destination already holds the latest managed snapshot (reachable
  # via a future-dated seed or clock skew), there is nothing to send — the run
  # must skip the transfer instead of building a self-referential
  # `zfs send -I X X`, and pruning still proceeds.
  def test_skips_transfer_when_destination_already_at_latest
    rep = build(
      [[/zfs list -t snapshot/, SRC_THREE]],
      [[/zfs list -t snapshot/, DST_THREE]],
      replication(keep: 1)
    )
    capture_io { rep.run }
    assert_empty @src.pipelines, "must not build a transfer when common == latest"
    refute_empty @src.commands.grep(/zfs destroy/), "pruning still proceeds"
    refute_empty @dst.commands.grep(/zfs destroy/), "destination pruning still proceeds"
  end

  # The snapshot this run just created should be the latest; when it is not,
  # something is future-dated or a clock is skewed — say so.
  def test_warns_when_new_snapshot_is_not_latest
    rep = build(
      [[/zfs list -t snapshot/, SRC_THREE]], # canned listing omits the new snapshot
      [[/zfs list -t snapshot/, DST_THREE]],
      replication
    )
    log_io = StringIO.new
    original = ZFSReplicate.instance_variable_get(:@logger)
    ZFSReplicate.instance_variable_set(:@logger, Logger.new(log_io))
    begin
      rep.run
    ensure
      ZFSReplicate.instance_variable_set(:@logger, original)
    end
    assert_match(/future-dated|clock/, log_io.string)
  end

  # A recursive receive applies child-by-child, and a child skipped at seed
  # time (e.g. a boot environment born after the seed snapshot) leaves the
  # parent looking healthy while the subtree is incomplete. Verify children
  # before pruning and name the hole.
  def test_recursive_verify_fails_when_destination_missing_a_child
    src_r = SRC_THREE + "tank/vms/be1@zfsreplicate-20260420-000000\n"
    rep = build(
      [[/zfs list -t snapshot -r /, src_r],
       [/zfs list -t snapshot -d 1 /, SRC_THREE]],
      [[/zfs list -t snapshot -r /, DST_THREE], # no be1 on the destination
       [/zfs list -t snapshot -d 1 /, [DST_TWO, DST_THREE]]],
      replication(recursive: true, keep: 1)
    )
    err = assert_raises(ZFSReplicate::ExecutorError) { rep.run }
    assert_match(/be1/, err.message)
    assert_empty @src.commands.grep(/zfs destroy/), "must not prune source"
    assert_empty @dst.commands.grep(/zfs destroy/), "must not prune destination"
  end

  def test_recursive_verify_passes_when_children_match
    src_r = SRC_THREE + "tank/vms/be1@zfsreplicate-20260420-000000\n"
    dst_r = DST_THREE + "backup/vms/be1@zfsreplicate-20260420-000000\n"
    rep = build(
      [[/zfs list -t snapshot -r /, src_r],
       [/zfs list -t snapshot -d 1 /, SRC_THREE]],
      [[/zfs list -t snapshot -r /, dst_r],
       [/zfs list -t snapshot -d 1 /, [DST_TWO, DST_THREE]]],
      replication(recursive: true, keep: 1)
    )
    rep.run
    refute_empty @src.commands.grep(/zfs destroy/), "expected pruning after clean verify"
  end

  def test_retries_then_succeeds_and_switches_to_resume
    rep = build(
      [[/zfs list -t snapshot/, SRC_THREE]],
      [[/zfs list -t snapshot/, DST_AFTER_FULL],
       [/zfs list -H -o name/, :raise],
       [/receive_resume_token/, ["-", "-", "1-resumetoken"]]],
      replication,
      src_failures: 1
    )
    rep.run
    assert_equal 2, @src.pipelines.length
    assert_equal 'zfs send -t 1-resumetoken', @src.pipelines[1][0]
    assert_equal 'zfs recv -u -s -x mountpoint backup/vms', @src.pipelines[1][1]
    assert_equal [5], @delays
  end

  def test_gives_up_after_max_retries
    rep = build(
      [[/zfs list -t snapshot/, SRC_THREE]],
      [[/zfs list -t snapshot/, ""],
       [/zfs list -H -o name/, :raise],
       [/receive_resume_token/, "-"]],
      replication(max_retries: 3),
      src_failures: 4
    )
    assert_raises(ZFSReplicate::ExecutorError) { rep.run }
    assert_equal 4, @src.pipelines.length
    assert_equal [5, 10, 20], @delays
  end

  def test_resumes_leftover_token_before_creating_snapshot
    rep = build(
      [[/zfs list -t snapshot/, SRC_THREE]],
      [[/zfs list -t snapshot/, DST_AFTER_FULL],
       [/zfs list -H -o name/, :raise],
       [/receive_resume_token/, ["1-leftover", "1-leftover", "-"]]],
      replication
    )
    rep.run
    # First pipeline is the leftover resume; a fresh send follows.
    assert_equal 'zfs send -t 1-leftover', @src.pipelines[0][0]
    assert_equal 'zfs recv -u -s -x mountpoint backup/vms', @src.pipelines[0][1]
    assert_equal 2, @src.pipelines.length
    # The leftover resume happens before the new source snapshot is created.
    resume_idx = @src.events.index { |kind, v| kind == :pipeline && v == 'zfs send -t 1-leftover' }
    snap_idx   = @src.events.index { |kind, v| kind == :run && v =~ /\Azfs snapshot / }
    assert resume_idx < snap_idx, "expected leftover resume before snapshot creation"
  end

  # A resume token whose source snapshot is gone fails on every attempt until a
  # human runs `zfs recv -A`; retrying is pointless and the error must say how
  # to recover, or one odd interruption becomes a permanent unattended outage.
  def test_unresumable_token_fails_fast_with_remediation
    @delays = []
    @src = RecordingExecutor.new(
      [[/zfs list -t snapshot/, SRC_THREE]],
      pipeline_failures: 99,
      pipeline_error: "ssh exited with status 1: cannot receive: incremental source 1-stale does not exist"
    )
    @dst = RecordingExecutor.new([
      [/receive_resume_token/, "1-stale"],
      [/zfs list -t snapshot/, ""],
      [/zfs list -H -o name/, "backup/vms\n"]
    ])
    rep = ZFSReplicate::Replicator.new(replication, src_executor: @src,
                                       dst_executor: @dst,
                                       sleeper: ->(s) { @delays << s })
    err = assert_raises(ZFSReplicate::ExecutorError) { rep.run }
    assert_match /zfs recv -A backup\/vms/, err.message
    assert_equal 1, @src.pipelines.length, "must not retry an unresumable token"
    assert_empty @delays
  end

  def test_resume_disabled_is_single_attempt_no_retry
    rep = build(
      [[/zfs list -t snapshot/, SRC_THREE]],
      [[/zfs list -t snapshot/, DST_AFTER_FULL], [/zfs list -H -o name/, :raise]],
      replication(resume: false),
      src_failures: 1
    )
    assert_raises(ZFSReplicate::ExecutorError) { rep.run }
    assert_equal 1, @src.pipelines.length
    assert_equal 'zfs recv -u -F -x mountpoint backup/vms', @src.pipelines[0][1]
    assert_empty @delays
  end

  def test_raw_send_flag_reaches_send_stage
    rep = build(
      [[/zfs list -t snapshot/, SRC_THREE]],
      [[/zfs list -t snapshot/, DST_AFTER_FULL], [/zfs list -H -o name/, :raise]],
      replication(raw_send: true, compressed_send: true)
    )
    rep.run
    send_cmd = @src.pipelines.first[0]
    assert_match(/\Azfs send -w /, send_cmd,
                 "expected '-w' (and no '-c') in send stage, got: #{send_cmd.inspect}")
  end

  def test_compressed_send_flag_reaches_send_stage
    rep = build(
      [[/zfs list -t snapshot/, SRC_THREE]],
      [[/zfs list -t snapshot/, DST_AFTER_FULL], [/zfs list -H -o name/, :raise]],
      replication(compressed_send: true)
    )
    rep.run
    send_cmd = @src.pipelines.first[0]
    assert_match(/\Azfs send -c /, send_cmd,
                 "expected '-c' flag in send stage, got: #{send_cmd.inspect}")
  end

  def test_timeout_is_passed_to_run_pipeline
    rep = build(
      [[/zfs list -t snapshot/, SRC_THREE]],
      [[/zfs list -t snapshot/, DST_AFTER_FULL], [/zfs list -H -o name/, :raise]],
      replication(timeout: 600)
    )
    rep.run
    assert_includes @src.pipeline_timeouts, 600
  end

  def test_bwlimit_inserts_mbuffer_stage_mid_pipeline
    original = ZFSReplicate::Replicator.method(:ensure_mbuffer!)
    ZFSReplicate::Replicator.define_singleton_method(:ensure_mbuffer!) { |_executor| nil }
    begin
      rep = build(
        [[/zfs list -t snapshot/, SRC_THREE]],
        [[/zfs list -t snapshot/, DST_AFTER_FULL], [/zfs list -H -o name/, :raise]],
        replication(bwlimit: '50m')
      )
      rep.run
      stages = @src.pipelines.first
      assert_equal 3, stages.length,
                   "expected 3 pipeline stages (send|mbuffer|recv), got: #{stages.inspect}"
      assert_equal 'mbuffer -q -R 50m', stages[1],
                   "expected mbuffer as middle stage, got: #{stages[1].inspect}"
      assert_match(/\Azfs send /, stages[0])
      assert_match(/zfs recv /, stages[2])
    ensure
      ZFSReplicate::Replicator.define_singleton_method(:ensure_mbuffer!, original)
    end
  end
end
