# frozen_string_literal: true
require 'test_helper'
require 'zfsreplicate/executor'
require 'zfsreplicate/job_runner'

Job = Struct.new(:name)

class TestJobRunner < Minitest::Test
  def test_runs_every_item
    items = [Job.new('a'), Job.new('b'), Job.new('c')]
    seen = []
    mutex = Mutex.new
    outcomes = ZFSReplicate::JobRunner.new(items, concurrency: 2).run do |job|
      mutex.synchronize { seen << job.name }
      :ok
    end
    assert_equal %w[a b c], seen.sort
    assert_equal 3, outcomes.length
    assert(outcomes.all? { |o| o.status == :ok })
  end

  def test_records_block_status_symbol
    outcomes = ZFSReplicate::JobRunner.new([Job.new('a')], concurrency: 1).run { |_| :skipped }
    assert_equal :skipped, outcomes.first.status
  end

  def test_failure_isolated_and_recorded
    items = [Job.new('good'), Job.new('bad')]
    outcomes = ZFSReplicate::JobRunner.new(items, concurrency: 1).run do |job|
      raise ZFSReplicate::ExecutorError, 'boom' if job.name == 'bad'
      :ok
    end
    by_name = outcomes.each_with_object({}) { |o, h| h[o.name] = o }
    assert_equal :ok, by_name['good'].status
    assert_equal :failed, by_name['bad'].status
    assert_instance_of ZFSReplicate::ExecutorError, by_name['bad'].error
  end

  def test_concurrency_below_one_still_runs
    outcomes = ZFSReplicate::JobRunner.new([Job.new('a')], concurrency: 0).run { |_| :ok }
    assert_equal 1, outcomes.length
  end

  def test_sets_thread_local_tag_during_block
    tag = nil
    ZFSReplicate::JobRunner.new([Job.new('tagged')], concurrency: 1).run do |_|
      tag = Thread.current[:zfsreplicate_job]
      :ok
    end
    assert_equal 'tagged', tag
  end
end
