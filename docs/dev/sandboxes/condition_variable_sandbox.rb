# frozen_string_literal: true
#
# condition_variable_sandbox.rb
#
# A ConditionVariable lets a thread SLEEP until a condition becomes true,
# instead of busy-looping and burning CPU. It is ALWAYS paired with a Mutex:
#   * the Mutex protects the shared state
#   * the ConditionVariable coordinates WAITING on that state
#
# We hand-build a tiny blocking queue — essentially what Ruby's built-in Queue
# does internally — so the wait/signal mechanics are visible.
#
# Run:  ruby examples/condition_variable_sandbox.rb

class SimpleBlockingQueue
  def initialize
    @items     = []
    @mutex     = Mutex.new
    @not_empty = ConditionVariable.new
  end

  def push(item)
    @mutex.synchronize do
      @items << item
      # Wake ONE thread sleeping in pop. We hold the mutex while signalling,
      # which is the safe habit (no lost-wakeup races).
      @not_empty.signal
    end
  end

  def pop
    @mutex.synchronize do
      # WHILE, not IF. After being woken we re-check: there may have been a
      # spurious wakeup, or another consumer may have grabbed the item first.
      while @items.empty?
        # wait() atomically: (1) releases @mutex so a producer can push,
        # (2) sleeps until signalled, (3) re-acquires @mutex before returning.
        @not_empty.wait(@mutex)
      end
      @items.shift
    end
  end
end

# --- tiny timestamped logger so we can SEE who sleeps and who wakes ----------
START = Process.clock_gettime(Process::CLOCK_MONOTONIC)
LOG_MUTEX = Mutex.new
def say(msg)
  stamp = Process.clock_gettime(Process::CLOCK_MONOTONIC) - START
  LOG_MUTEX.synchronize { puts format('[%5.2fs] %s', stamp, msg) }
end

queue = SimpleBlockingQueue.new

# Start 3 consumers BEFORE anything is in the queue. They will block in pop().
consumers = 3.times.map do |i|
  Thread.new do
    say "consumer #{i}: calling pop (queue empty -> will sleep)"
    item = queue.pop
    say "consumer #{i}: woke up and got #{item.inspect}"
  end
end

# Give all three time to reach pop() and go to sleep. During this second they
# are NOT spinning — they use ~0 CPU. That is the win over busy-waiting.
sleep 1
say 'producer: pushing 3 items now'
%w[apple banana cherry].each { |fruit| queue.push(fruit) }

consumers.each(&:join)
say 'all consumers done'

puts
puts 'What to notice:'
puts '  * For ~1s the consumers printed nothing — they were ASLEEP, not spinning.'
puts '  * Each push woke exactly one consumer (signal), which then re-acquired'
puts '    the mutex inside wait() and returned holding it.'
puts '  * The `while @items.empty?` loop (not `if`) is what makes it correct.'
