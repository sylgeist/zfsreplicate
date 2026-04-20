# lib/zfsreplicate/cli.rb
require 'optparse'
require_relative 'config'
require_relative 'replicator'
require_relative 'log'

module ZFSReplicate
  module CLI
    DEFAULT_CONFIG = File.expand_path('~/.config/zfsreplicate/config.yml')

    USAGE = <<~USAGE
      Usage: zfsreplicate [options] <command> [args]

      Commands:
        sync [name]         Run replication job(s). Omit name to run all.
        list                List configured replications.
        help                Show this message.

      Options:
        -c, --config FILE   Config file (default: #{DEFAULT_CONFIG})
        -v, --verbose       Verbose output
        -n, --dry-run       Print actions without executing

    USAGE

    def self.run(argv)
      options = { config: DEFAULT_CONFIG, verbose: false, dry_run: false }

      parser = OptionParser.new do |o|
        o.on('-c', '--config FILE') { |f| options[:config] = f }
        o.on('-v', '--verbose')     { options[:verbose] = true }
        o.on('-n', '--dry-run')     { options[:dry_run] = true }
      end

      begin
        parser.parse!(argv)
      rescue OptionParser::InvalidOption => e
        warn e.message
        exit 1
      end

      ZFSReplicate.log_level = options[:verbose] ? Logger::DEBUG : Logger::INFO

      cmd = argv.shift
      case cmd
      when 'help', '--help', '-h', nil
        puts USAGE
        exit(cmd ? 0 : 1)
      when 'list'
        cmd_list(options)
      when 'sync'
        cmd_sync(argv.first, options)
      else
        warn "Unknown command: #{cmd}\n\n#{USAGE}"
        exit 1
      end
    end

    def self.cmd_list(options)
      cfg = Config.load(options[:config])
      cfg.replications.each do |r|
        src = r.source.local? ? r.source.dataset : "#{r.source.user}@#{r.source.host}:#{r.source.dataset}"
        dst = r.destination.local? ? r.destination.dataset : "#{r.destination.user}@#{r.destination.host}:#{r.destination.dataset}"
        puts "#{r.name}: #{src} \u2192 #{dst} (keep #{r.keep_snapshots})"
      end
    rescue ConfigError => e
      warn "Config error: #{e.message}"
      exit 1
    end

    def self.cmd_sync(name, options)
      cfg = Config.load(options[:config])
      jobs = name ? cfg.replications.select { |r| r.name == name } : cfg.replications

      if jobs.empty?
        warn name ? "No replication named '#{name}'" : "No replications configured"
        exit 1
      end

      jobs.each do |rep|
        ZFSReplicate.logger.info("Starting replication: #{rep.name}")
        if options[:dry_run]
          puts "[dry-run] Would replicate #{rep.source.dataset} \u2192 #{rep.destination.dataset}"
        else
          Replicator.new(rep).run
        end
      end
    rescue ConfigError => e
      warn "Config error: #{e.message}"
      exit 1
    rescue ExecutorError => e
      warn "Replication failed: #{e.message}"
      exit 1
    end
  end
end
