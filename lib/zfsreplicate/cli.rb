# frozen_string_literal: true
# lib/zfsreplicate/cli.rb
require 'optparse'
require_relative 'config'
require_relative 'replicator'
require_relative 'log'
require_relative 'version'
require_relative 'job_runner'
require_relative 'lock'

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
        -V, --version       Print version and exit
        -j, --concurrency N Run up to N jobs in parallel (default 1)
            --lock-dir DIR  Directory for per-job lock files (default /var/run/zfsreplicate)

    USAGE

    def self.run(argv)
      options = { config: DEFAULT_CONFIG, verbose: false, dry_run: false }

      parser = OptionParser.new do |o|
        o.on('-c', '--config FILE') { |f| options[:config] = f }
        o.on('-v', '--verbose')     { options[:verbose] = true }
        o.on('-n', '--dry-run')     { options[:dry_run] = true }
        o.on('-V', '--version')     { puts "zfsreplicate #{VERSION}"; exit 0 }
        o.on('-j', '--concurrency N', Integer) { |n| options[:concurrency] = n }
        o.on('--lock-dir DIR')                 { |d| options[:lock_dir] = d }
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
        exit 2
      end

      if options[:dry_run]
        jobs.each do |rep|
          puts "[dry-run] Would replicate #{rep.source.dataset} \u2192 #{rep.destination.dataset}"
        end
        exit 0
      end

      concurrency = options[:concurrency] || cfg.concurrency
      lock_dir    = options[:lock_dir]    || cfg.lock_dir

      outcomes = JobRunner.new(jobs, concurrency: concurrency).run do |rep|
        result = Lock.acquire(rep.name, dir: lock_dir) do
          ZFSReplicate.logger.info("Starting replication: #{rep.name}")
          Replicator.new(rep).run
          :ok
        end
        ZFSReplicate.logger.warn('already running, skipping') if result == Lock::SKIPPED
        result
      end

      exit 1 if outcomes.any? { |o| o.status == :failed }
      exit 0
    rescue ConfigError => e
      warn "Config error: #{e.message}"
      exit 2
    end
  end
end
