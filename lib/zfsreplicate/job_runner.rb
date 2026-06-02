# frozen_string_literal: true
# lib/zfsreplicate/job_runner.rb
require_relative 'log'
require_relative 'replicator'

module ZFSReplicate
  JobResult = Struct.new(:name, :status, :duration, :error)

  # Runs independent replication jobs across a bounded thread pool. Jobs are
  # IO-bound (zfs/ssh subprocesses), so threads give real parallelism. A failed
  # or skipped job never stops the others; all results are collected and returned.
  class JobRunner
    def initialize(jobs, concurrency:, lock_factory:,
                   execute: ->(job) { Replicator.new(job).run },
                   clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @jobs = jobs
      @concurrency = concurrency
      @lock_factory = lock_factory
      @execute = execute
      @clock = clock
    end

    def run
      return [] if @jobs.empty?

      queue = Queue.new
      @jobs.each { |j| queue << j }
      results = []
      mutex = Mutex.new

      worker_count = [@concurrency, @jobs.size].min
      workers = Array.new(worker_count) do
        Thread.new do
          loop do
            # non-blocking: pop(true) raises ThreadError when the queue is
            # empty, which is our signal that this worker is done.
            job = begin
              queue.pop(true)
            rescue ThreadError
              break
            end
            result = run_one(job)
            mutex.synchronize { results << result }
          end
        end
      end
      workers.each(&:join)
      results
    end

    private

    def run_one(job)
      Thread.current[:zfsreplicate_job] = job.name
      lock = @lock_factory.call(job.name)
      unless lock.acquire
        ZFSReplicate.logger.warn("Skipping #{job.name}: already running")
        return JobResult.new(job.name, :skipped, 0.0, nil)
      end

      start = @clock.call
      begin
        @execute.call(job)
        JobResult.new(job.name, :ok, @clock.call - start, nil)
      rescue StandardError => e
        ZFSReplicate.logger.error("#{job.name} failed: #{e.message}")
        JobResult.new(job.name, :failed, @clock.call - start, e.message)
      ensure
        lock.release
      end
    ensure
      Thread.current[:zfsreplicate_job] = nil
    end
  end
end
