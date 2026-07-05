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
    def run_pipeline(*cmds)
      cmds = cmds.flatten
      raise ArgumentError, 'run_pipeline requires at least 2 stages' if cmds.length < 2

      first = local? ? cmds.first : "#{@ssh_prefix} #{Shellwords.escape(cmds.first)}"
      stages = [first, *cmds[1..]]
      ZFSReplicate.logger.debug("exec pipeline: #{stages.join(' | ')}")

      err_r, err_w = IO.pipe
      last_stdout, wait_threads = Open3.pipeline_r(
        *stages.map { |c| ['/bin/sh', '-c', c] },
        err: err_w
      )
      err_w.close
      err_reader = Thread.new { err_r.read }
      stdout = last_stdout.read
      last_stdout.close
      stderr = err_reader.value
      err_r.close

      statuses = wait_threads.map(&:value)
      failed = statuses.find { |s| !s.success? }
      if failed
        raise ExecutorError, "pipeline failed (status #{failed.exitstatus}): #{stderr.strip}"
      end
      stdout
    end
  end
end
