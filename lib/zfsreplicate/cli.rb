# frozen_string_literal: true
# lib/zfsreplicate/cli.rb
require 'optparse'
require 'fileutils'
require_relative 'config'
require_relative 'replicator'
require_relative 'job_runner'
require_relative 'lock'
require_relative 'report'
require_relative 'log'
require_relative 'version'

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
        -j, --concurrency N Run up to N jobs in parallel (default 1)
            --lock-dir DIR  Directory for per-job lock files (overrides config)
        -V, --version       Print version and exit

    USAGE

    def self.run(argv)
      options = { config: DEFAULT_CONFIG, verbose: false, dry_run: false }

      parser = OptionParser.new do |o|
        o.on('-c', '--config FILE') { |f| options[:config] = f }
        o.on('-v', '--verbose')     { options[:verbose] = true }
        o.on('-n', '--dry-run')     { options[:dry_run] = true }
        o.on('-j', '--concurrency N', Integer) { |n| options[:concurrency] = n }
        o.on('--lock-dir DIR')      { |d| options[:lock_dir] = d }
        o.on('-V', '--version')     { puts "zfsreplicate #{VERSION}"; exit 0 }
      end

      begin
        parser.parse!(argv)
      rescue OptionParser::ParseError => e
        warn e.message
        exit 2
      end

      if options[:concurrency] && options[:concurrency] < 1
        warn 'concurrency must be >= 1'
        exit 2
      end

      ZFSReplicate.log_level = options[:verbose] ? Logger::DEBUG : Logger::INFO

      cmd = argv.shift
      case cmd
      when 'help', '--help', '-h', nil
        puts USAGE
        # An explicit `help` is success; no command at all is a usage error.
        exit(cmd ? 0 : 2)
      when 'list'
        cmd_list(options)
      when 'sync'
        cmd_sync(argv.first, options)
      else
        warn "Unknown command: #{cmd}\n\n#{USAGE}"
        exit 2
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
      exit 2
    end

    def self.exit_code_for(results)
      results.any? { |r| r.status == :failed } ? 1 : 0
    end

    # Map a job name to a lock filename. Job names must remain distinct after
    # this sanitization (characters outside [A-Za-z0-9_.-] collapse to '_') or
    # they will share a lock file and serialize instead of running in parallel.
    def self.lock_filename(name)
      name.gsub(/[^A-Za-z0-9_.-]/, '_')
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
        return
      end

      concurrency = options[:concurrency] || cfg.concurrency # CLI flag overrides config
      lock_dir = options[:lock_dir] || cfg.lock_dir           # CLI flag overrides config
      begin
        FileUtils.mkdir_p(lock_dir)
      rescue SystemCallError => e
        warn "Cannot create lock directory #{lock_dir}: #{e.message}"
        exit 2
      end
      lock_factory = lambda do |job_name|
        Lock.new(File.join(lock_dir, "#{lock_filename(job_name)}.lock"))
      end

      results = JobRunner.new(jobs, concurrency: concurrency,
                                    lock_factory: lock_factory).run
      Report.summary_lines(results).each { |line| puts line }
      exit exit_code_for(results)
    rescue ConfigError => e
      warn "Config error: #{e.message}"
      exit 2
    end
  end
end
