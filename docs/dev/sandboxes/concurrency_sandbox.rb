# frozen_string_literal: true
#
# concurrency_sandbox.rb — a runnable companion to JobRunner.
#
# It mirrors the same three pieces JobRunner uses:
#   * a Queue        — thread-safe inbox of work
#   * N Thread.new   — workers pulling from the queue in parallel
#   * a Mutex        — guarding the one piece of SHARED state
#
# The job here is trivial: sum the numbers 1..2000. The interesting part is
# what happens to that shared running total WITHOUT the mutex.
#
# Run:  ruby examples/concurrency_sandbox.rb

WORKERS  = 4
ITEMS    = (1..2000).to_a
EXPECTED = ITEMS.sum          # the one true answer: 2_001_000

# A deliberately race-prone accumulator.
#
# A running total is shared mutable state. Updating it is a READ-MODIFY-WRITE:
#   current = @total      # read
#   @total  = current + n # write
# If two threads read the SAME `current` before either writes, one write
# clobbers the other and that addition is silently lost.
#
# Normally Ruby's GIL makes this hard to observe (the VM rarely switches
# threads mid-line). The `Thread.pass` FORCES a thread switch right between the
# read and the write, so the race shows up every time — it's not cheating, it
# just makes a real-but-rare bug reproducible on demand.
class Accumulator
  attr_reader :total

  def initialize
    @total = 0
  end

  # No protection: workers stomp on each other.
  def add_unsafe(n)
    current = @total
    Thread.pass            # <-- yield to another thread mid-update
    @total = current + n
  end

  # Protected: only one thread is inside the block at a time, so the
  # read-modify-write is atomic from every other thread's point of view.
  def add_safe(n, mutex)
    mutex.synchronize do
      current = @total
      Thread.pass          # even with a yield here, the lock holds others off
      @total = current + n
    end
  end
end

def run_pool(use_mutex:)
  queue = Queue.new
  ITEMS.each { |n| queue << n }   # load the work (cf. JobRunner filling its queue)

  acc   = Accumulator.new
  mutex = Mutex.new

  workers = Array.new(WORKERS) do
    Thread.new do
      loop do
        n = begin
          queue.pop(true)         # non-blocking; raises ThreadError when empty
        rescue ThreadError
          break                   # queue drained -> this worker exits
        end
        use_mutex ? acc.add_safe(n, mutex) : acc.add_unsafe(n)
      end
    end
  end

  workers.each(&:join)            # wait for all workers (cf. JobRunner)
  acc.total
end

def report(label, use_mutex:)
  puts "#{label}:"
  5.times do |i|
    got    = run_pool(use_mutex: use_mutex)
    status = got == EXPECTED ? "ok" : "WRONG — lost #{EXPECTED - got}"
    puts format("  trial %d: %8d   %s", i + 1, got, status)
  end
  puts
end

puts "Summing 1..2000 with #{WORKERS} threads. Correct answer = #{EXPECTED}"
puts
report("WITHOUT mutex (shared total is unguarded)", use_mutex: false)
report("WITH mutex (shared total is guarded)",      use_mutex: true)

puts "Takeaways:"
puts "  * The Queue itself is thread-safe — pulling work never corrupted anything."
puts "  * The bug was ONLY around the shared @total. That's the state a Mutex guards."
puts "  * In JobRunner, `results << run_one(job)` is that exact shared write,"
puts "    which is why it sits inside `mutex.synchronize { ... }`."
