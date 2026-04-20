# lib/zfsreplicate/log.rb
require 'logger'

module ZFSReplicate
  def self.logger
    @logger ||= begin
      l = Logger.new($stderr)
      l.progname = 'zfsreplicate'
      l.formatter = ->(sev, _t, prog, msg) { "[#{sev}] #{prog}: #{msg}\n" }
      l
    end
  end

  def self.log_level=(level)
    logger.level = level
  end
end
