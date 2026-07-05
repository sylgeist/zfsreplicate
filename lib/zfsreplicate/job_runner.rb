# frozen_string_literal: true
require_relative 'log'

module ZFSReplicate
  # Runs items through a fixed pool of worker threads. The block returns a
  # status symbol per item; a raised StandardError is caught and recorded as
  # :failed so one item's failure never stops the others.
  class JobRunner
    Outcome = Struct.new(:name, :status, :error)

    def initialize(items, concurrency: 1)
      @items = items.to_a
      @concurrency = concurrency.to_i
      @concurrency = 1 if @concurrency < 1
    end

    def run(&block)
      queue = Queue.new
      @items.each { |item| queue << item }
      results = []
      results_mutex = Mutex.new
      worker_count = [@concurrency, @items.length].min
      worker_count = 1 if worker_count < 1

      threads = Array.new(worker_count) do
        Thread.new do
          loop do
            item = begin
              queue.pop(true) # non-blocking; raises ThreadError when empty
            rescue ThreadError
              break
            end
            outcome = run_item(item, &block)
            results_mutex.synchronize { results << outcome }
          end
        end
      end
      threads.each(&:join)
      results
    end

    private

    def run_item(item)
      Thread.current[:zfsreplicate_job] = item.name
      status = yield(item)
      Outcome.new(item.name, status, nil)
    rescue StandardError => e
      ZFSReplicate.logger.error("job #{item.name} failed: #{e.message}")
      Outcome.new(item.name, :failed, e)
    ensure
      Thread.current[:zfsreplicate_job] = nil
    end
  end
end
