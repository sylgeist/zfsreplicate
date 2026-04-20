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
      opts = "-o BatchMode=yes -o StrictHostKeyChecking=accept-new -p #{port}"
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

    # Stream src_cmd | dst_cmd, return dst stdout. Used for zfs send | zfs recv.
    def run_pipeline(src_cmd, dst_cmd)
      full_src = local? ? src_cmd : "#{@ssh_prefix} #{Shellwords.escape(src_cmd)}"
      stdout, stderr, status = Open3.capture3("#{full_src} | #{dst_cmd}")
      unless status.success?
        raise ExecutorError, "pipeline failed (status #{status.exitstatus}): #{stderr.strip}"
      end
      stdout
    end
  end
end
