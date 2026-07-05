# frozen_string_literal: true
# lib/zfsreplicate/log.rb
require 'logger'

module ZFSReplicate
  # Formatter shared by the real logger and tests. Includes the current
  # thread's job tag (set by JobRunner) so concurrent job lines are attributable.
  def self.log_formatter
    lambda do |sev, _t, prog, msg|
      job = Thread.current[:zfsreplicate_job]
      name = job ? "#{prog}(#{job})" : prog
      "[#{sev}] #{name}: #{msg}\n"
    end
  end

  # NOTE: @logger ||= is not thread-safe. The main thread must call logger (via
  # log_level=) before any JobRunner worker thread runs, so the instance is
  # always created on the main thread and subsequent reads are just reads.
  def self.logger
    @logger ||= begin
      l = Logger.new($stderr)
      l.progname = 'zfsreplicate'
      l.formatter = log_formatter
      l
    end
  end

  def self.log_level=(level)
    logger.level = level
  end
end
