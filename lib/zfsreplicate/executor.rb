# frozen_string_literal: true
require 'open3'
require 'shellwords'
require_relative 'log'

module ZFSReplicate
  class ExecutorError < StandardError; end

  class Executor
    attr_reader :ssh_prefix

    def self.local
      new(nil)
    end

    def self.remote(host:, user: 'root', port: 22, identity: nil)
      opts = "-o BatchMode=yes -o StrictHostKeyChecking=accept-new " \
             "-o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 " \
             "-p #{port}"
      opts += " -i #{identity}" if identity
      new("ssh #{opts} #{user}@#{host}")
    end

    def initialize(ssh_prefix)
      @ssh_prefix = ssh_prefix
    end

    def local?
      @ssh_prefix.nil?
    end

    def run(cmd)
      full = local? ? cmd : "#{@ssh_prefix} #{Shellwords.escape(cmd)}"
      ZFSReplicate.logger.debug("exec: #{full}")
      stdout, stderr, status = Open3.capture3(full)
      unless status.success?
        raise ExecutorError, "#{full.split.first} exited with status #{status.exitstatus}: #{stderr.strip}"
      end
      stdout
    end

    # Stream N stage commands as a pipeline (stage1 | stage2 | ... | stageN),
    # return the last stage's stdout. When remote, wraps only the first stage with
    # the ssh prefix. Detects a failure on ANY stage (not just the last) via
    # Open3.pipeline_r, avoiding shell pipe masking of intermediate failures.
    GRACE_PERIOD = 5 # seconds to wait for graceful exit after TERM before KILL

    def run_pipeline(*cmds, timeout: nil)
      cmds = cmds.flatten
      raise ArgumentError, 'run_pipeline requires at least 2 stages' if cmds.length < 2

      first = local? ? cmds.first : "#{@ssh_prefix} #{Shellwords.escape(cmds.first)}"
      stages = [first, *cmds[1..]]
      ZFSReplicate.logger.debug("exec pipeline: #{stages.join(' | ')}")

      err_r, err_w = IO.pipe
      spawn_opts = { err: err_w }
      spawn_opts[:pgroup] = true if timeout # separate groups only when we may need to kill them
      last_stdout, wait_threads = Open3.pipeline_r(
        *stages.map { |c| ['/bin/sh', '-c', c] },
        **spawn_opts
      )
      err_w.close
      pids = wait_threads.map(&:pid)

      err_reader = Thread.new { err_r.read }
      worker = Thread.new do
        out = begin
          last_stdout.read
        ensure
          last_stdout.close
        end
        [out, wait_threads.map(&:value)]
      end

      if timeout && !worker.join(timeout)
        terminate_pipeline(pids)
        worker.join
        err_reader.value
        err_r.close
        raise ExecutorError, "pipeline timed out after #{timeout}s"
      end

      stdout, statuses = worker.value
      stderr = err_reader.value
      err_r.close

      failed = statuses.find { |s| !s.success? }
      if failed
        raise ExecutorError, "pipeline failed (status #{failed.exitstatus}): #{stderr.strip}"
      end
      stdout
    end

    private

    # TERM every stage's process group, wait up to GRACE_PERIOD for them ALL to
    # exit, then KILL any survivors. Gates on all stage groups exiting (not on the
    # stdout worker, whose last stage can exit while an upstream stage survives),
    # so the pipes are guaranteed to reach EOF afterward.
    def terminate_pipeline(pids)
      signal_groups(pids, 'TERM')
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + GRACE_PERIOD
      until pids.all? { |pid| group_dead?(pid) }
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.05
      end
      signal_groups(pids, 'KILL')
    end

    def signal_groups(pids, sig)
      pids.each do |pid|
        Process.kill(sig, -pid) # negative pid -> the whole process group
      rescue Errno::ESRCH
        # process/group already gone
      end
    end

    def group_dead?(pid)
      Process.kill(0, -pid) # signal 0 = existence check on the group
      false
    rescue Errno::ESRCH
      true
    rescue Errno::EPERM
      # EPERM means the group exists but we lack permission to signal it (e.g.
      # macOS sandbox); treat as alive so the caller keeps waiting/kills.
      false
    end
  end
end
