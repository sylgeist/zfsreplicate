# frozen_string_literal: true
#
# config_reload_sandbox.rb
#
# A long-running daemon that reloads its config WITHOUT restarting, using a
# Mutex + ConditionVariable. Three patterns you'll reuse constantly:
#
#   1. NOTIFY     — workers sleep until config changes; reload broadcasts to all.
#   2. SNAPSHOT   — a worker grabs a consistent copy under the lock, then does
#                   its work WITHOUT holding the lock. A reload that lands during
#                   a job does NOT change the config out from under that job.
#   3. VERSIONING — an integer version lets a worker ask "is there anything newer
#                   than what I already applied?" It also coalesces: if several
#                   reloads happen during one job, the worker just jumps to the
#                   latest next cycle (it doesn't replay every intermediate one).
#
# This demo drives the reloads on a timer so it runs to completion. The comment
# at the bottom shows how to trigger the exact same reload from SIGHUP.
#
# Run:  ruby examples/config_reload_sandbox.rb

require 'yaml'
require 'tmpdir'

CONFIG_PATH = File.join(Dir.tmpdir, 'zr-demo-config.yml')

class ConfigStore
  def initialize
    @data     = {}
    @version  = 0
    @shutdown = false
    @mutex    = Mutex.new
    @changed  = ConditionVariable.new
  end

  # Called by the reloader: swap config in and wake everyone. ALL workers care
  # about a config change, so broadcast (not signal).
  def replace(new_data)
    @mutex.synchronize do
      @data    = new_data
      @version += 1
      @changed.broadcast
    end
  end

  def shutdown!
    @mutex.synchronize do
      @shutdown = true
      @changed.broadcast
    end
  end

  # Block until there's a version newer than `since` (or we're shutting down),
  # then hand back a consistent [version, data, shutdown?] snapshot. The caller
  # uses that snapshot OUTSIDE the lock.
  def wait_for_change(since:)
    @mutex.synchronize do
      while !@shutdown && @version <= since
        @changed.wait(@mutex)        # release lock + sleep; re-acquire on wake
      end
      [@version, @data, @shutdown]
    end
  end
end

# --- timestamped logger ------------------------------------------------------
START = Process.clock_gettime(Process::CLOCK_MONOTONIC)
LOG = Mutex.new
def say(msg)
  t = Process.clock_gettime(Process::CLOCK_MONOTONIC) - START
  LOG.synchronize { puts format('[%5.2fs] %s', t, msg) }
end

def write_config(hash) = File.write(CONFIG_PATH, hash.to_yaml)
def load_config        = YAML.safe_load(File.read(CONFIG_PATH))

# --- the daemon --------------------------------------------------------------
store = ConfigStore.new

workers = 2.times.map do |i|
  Thread.new do
    seen = 0
    loop do
      version, data, stopping = store.wait_for_change(since: seen)
      break if stopping
      seen = version
      # We hold a SNAPSHOT now. Simulate a unit of work that takes time, using
      # `data`. Reloads that arrive during this sleep won't disturb this job.
      say "worker #{i}: applying config v#{version} -> greeting=#{data['greeting'].inspect}"
      sleep 0.4
    end
    say "worker #{i}: shut down"
  end
end

# Initial load (workers are blocked waiting at version 0; this wakes them).
write_config({ 'greeting' => 'hello (v1)' })
store.replace(load_config)                       # -> v1

sleep 0.2
write_config({ 'greeting' => 'hola (v2)' })
say 'main: reload while workers are mid-job (they should finish on v1)'
store.replace(load_config)                       # -> v2

sleep 0.1
write_config({ 'greeting' => 'bonjour (v3)' })
say 'main: another quick reload (v2 gets coalesced; workers jump to v3)'
store.replace(load_config)                       # -> v3

sleep 1
say 'main: shutting down'
store.shutdown!
workers.each(&:join)

# --- how you'd trigger this from SIGHUP in a real daemon ---------------------
# Signal handlers must be tiny and async-safe, so DON'T read the file in the
# handler. Push a token to a Queue and let a dedicated thread do the work:
#
#   reload_requests = Queue.new
#   Signal.trap('HUP') { reload_requests << :reload }     # minimal & safe
#   Thread.new do
#     loop do
#       reload_requests.pop                                # blocks until SIGHUP
#       store.replace(load_config)                         # re-read + swap in
#     end
#   end
#
# Then in production:  kill -HUP <pid>   reloads config with zero downtime.
