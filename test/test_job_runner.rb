# test/test_job_runner.rb
require 'test_helper'
require 'zfsreplicate/job_runner'

JobStub = Struct.new(:name)

class FakeLock
  def initialize(acquirable)
    @acquirable = acquirable
    @released = false
  end
  attr_reader :released
  def acquire; @acquirable; end
  def release; @released = true; end
end

class TestJobRunner < Minitest::Test
  # Returns [runner, executed_names_array]. locks maps name=>bool (default true).
  # failures maps name=>error_message (those jobs raise ExecutorError).
  def build(jobs, concurrency: 2, locks: {}, failures: {})
    executed = []
    emutex = Mutex.new
    lock_factory = ->(name) { FakeLock.new(locks.fetch(name, true)) }
    execute = lambda do |job|
      emutex.synchronize { executed << job.name }
      raise ZFSReplicate::ExecutorError, failures[job.name] if failures.key?(job.name)
    end
    runner = ZFSReplicate::JobRunner.new(
      jobs, concurrency: concurrency, lock_factory: lock_factory,
      execute: execute, clock: -> { 0.0 }
    )
    [runner, executed]
  end

  def test_all_jobs_succeed
    jobs = [JobStub.new('a'), JobStub.new('b'), JobStub.new('c')]
    runner, executed = build(jobs)
    results = runner.run
    assert_equal %w[a b c], results.map(&:name).sort
    assert(results.all? { |r| r.status == :ok })
    assert_equal %w[a b c], executed.sort
  end

  def test_one_failure_does_not_stop_others
    jobs = [JobStub.new('a'), JobStub.new('b'), JobStub.new('c')]
    runner, = build(jobs, failures: { 'b' => 'boom' })
    by_name = runner.run.to_h { |r| [r.name, r] }
    assert_equal :ok, by_name['a'].status
    assert_equal :failed, by_name['b'].status
    assert_equal 'boom', by_name['b'].error
    assert_equal :ok, by_name['c'].status
  end

  def test_locked_job_is_skipped_and_not_executed
    jobs = [JobStub.new('a'), JobStub.new('b')]
    runner, executed = build(jobs, locks: { 'a' => false, 'b' => true })
    by_name = runner.run.to_h { |r| [r.name, r] }
    assert_equal :skipped, by_name['a'].status
    assert_equal :ok, by_name['b'].status
    refute_includes executed, 'a'
    assert_includes executed, 'b'
  end

  def test_runs_all_jobs_with_low_concurrency
    jobs = (1..4).map { |i| JobStub.new("j#{i}") }
    runner, executed = build(jobs, concurrency: 2)
    results = runner.run
    assert_equal 4, results.length
    assert_equal 4, executed.length
  end

  def test_empty_jobs_returns_empty
    runner, = build([])
    assert_empty runner.run
  end

  def test_skip_path_resets_thread_local_tag
    Thread.current[:zfsreplicate_job] = nil
    runner = ZFSReplicate::JobRunner.new(
      [], concurrency: 1, lock_factory: ->(_n) { FakeLock.new(false) },
      execute: ->(_j) {}, clock: -> { 0.0 }
    )
    result = runner.send(:run_one, JobStub.new('x'))
    assert_equal :skipped, result.status
    assert_nil Thread.current[:zfsreplicate_job]
  ensure
    Thread.current[:zfsreplicate_job] = nil
  end

  def test_records_duration_from_clock
    times = [10.0, 13.5]
    runner = ZFSReplicate::JobRunner.new(
      [JobStub.new('a')], concurrency: 1,
      lock_factory: ->(_n) { FakeLock.new(true) },
      execute: ->(_j) {}, clock: -> { times.shift }
    )
    result = runner.run.first
    assert_in_delta 3.5, result.duration, 0.0001
  end
end
