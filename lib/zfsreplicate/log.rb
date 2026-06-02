# frozen_string_literal: true
# lib/zfsreplicate/log.rb
require 'logger'

module ZFSReplicate
  def self.logger
    @logger ||= begin
      l = Logger.new($stderr)
      l.progname = 'zfsreplicate'
      l.formatter = lambda do |sev, _t, prog, msg|
        tag = Thread.current[:zfsreplicate_job]
        prefix = tag ? "#{prog}[#{tag}]" : prog
        "[#{sev}] #{prefix}: #{msg}\n"
      end
      l
    end
  end

  def self.log_level=(level)
    logger.level = level
  end
end
