# frozen_string_literal: true
# lib/zfsreplicate/config.rb
require 'yaml'
require 'tmpdir'
require_relative 'log'

module ZFSReplicate
  class ConfigError < StandardError; end

  EndpointConfig = Struct.new(:host, :user, :dataset, :port, :identity) do
    def local?
      host.nil?
    end
  end

  ReplicationConfig = Struct.new(
    :name, :source, :destination, :recursive, :keep_snapshots, :snapshot_prefix,
    :force, :resume, :max_retries, :retry_delay, :compressed_send, :bwlimit, :timeout,
    :enabled, :raw_send
  )

  class Config
    DEFAULT_LOCK_DIR = File.join(Dir.tmpdir, 'zfsreplicate-locks')

    TOP_LEVEL_KEYS = %w[replications concurrency lock_dir].freeze
    REPLICATION_KEYS = %w[name source destination recursive keep_snapshots
                          snapshot_prefix force resume max_retries retry_delay
                          compressed_send bwlimit timeout enabled raw_send].freeze
    ENDPOINT_KEYS = %w[host user dataset port identity].freeze

    attr_reader :replications, :concurrency, :lock_dir, :warnings

    def self.load(path)
      raise ConfigError, "Config file not found: #{path}" unless File.exist?(path)
      raw = YAML.safe_load(File.read(path), permitted_classes: [])
      raise ConfigError, "Missing 'replications' key in #{path}" unless raw.is_a?(Hash) && raw.key?('replications')
      new(raw)
    end

    def initialize(raw)
      @warnings = []
      list = raw.fetch('replications')
      raise ConfigError, "'replications' must be a list" unless list.is_a?(Array)
      warn_unknown_keys(raw, TOP_LEVEL_KEYS, 'top level')
      @replications = list.map { |r| parse_replication(r) }
      reject_duplicate_names!
      @concurrency = parse_concurrency(raw, 'concurrency', 1)
      @lock_dir = raw.fetch('lock_dir', DEFAULT_LOCK_DIR)
    end

    private

    # A typo'd key silently applying the default is an unattended-failure mode,
    # so unrecognized keys are surfaced (but tolerated, for forward compat).
    def warn_unknown_keys(hash, known, where)
      (hash.keys.map(&:to_s) - known).each do |key|
        message = "Unknown config key '#{key}' at #{where} (ignored)"
        @warnings << message
        ZFSReplicate.logger.warn(message)
      end
    end

    # Duplicate names would share one lock file, so the second job silently
    # reports `skipped` on every run.
    def reject_duplicate_names!
      dups = @replications.group_by(&:name).select { |_, jobs| jobs.length > 1 }.keys
      return if dups.empty?
      raise ConfigError, "Duplicate replication name(s): #{dups.join(', ')}"
    end

    def parse_replication(r)
      raise ConfigError, "Each replication must be a mapping" unless r.is_a?(Hash)
      name = require_key(r, 'name')
      warn_unknown_keys(r, REPLICATION_KEYS, "replication '#{name}'")
      if r['force'] == true
        message = "replication '#{name}' sets force: true permanently, " \
                  "disarming the overwrite guard on every run; prefer the " \
                  "one-shot --force CLI flag"
        @warnings << message
        ZFSReplicate.logger.warn(message)
      end
      ReplicationConfig.new(
        name,
        parse_endpoint(require_key(r, 'source'), 'source'),
        parse_endpoint(require_key(r, 'destination'), 'destination'),
        r.fetch('recursive', false),
        positive_int(r, 'keep_snapshots', 7),
        zfs_name(r.fetch('snapshot_prefix', 'zfsreplicate'), 'snapshot_prefix'),
        r.fetch('force', false),
        r.fetch('resume', true),
        non_negative_int(r, 'max_retries', 3),
        non_negative_int(r, 'retry_delay', 5),
        r.fetch('compressed_send', true),
        bwlimit_or_nil(r),
        positive_int_or_nil(r, 'timeout'),
        boolean(r, 'enabled', true),
        boolean(r, 'raw_send', false)
      )
    end

    def parse_endpoint(e, role)
      raise ConfigError, "'#{role}' must be a mapping" unless e.is_a?(Hash)
      warn_unknown_keys(e, ENDPOINT_KEYS, "'#{role}'")
      EndpointConfig.new(
        e['host'],
        e.fetch('user', 'root'),
        zfs_name(require_key(e, 'dataset', "#{role}.dataset"), "#{role}.dataset",
                 allow_slash: true),
        e.fetch('port', 22),
        e['identity']
      )
    end

    def require_key(hash, key, label = key)
      raise ConfigError, "Missing required '#{label}' in replication config" unless hash.key?(key)
      hash.fetch(key)
    end

    # Config values are interpolated into shell commands, so restrict them to
    # the ZFS name charset up front: helpful errors instead of cryptic mid-run
    # shell failures, and no metacharacters can reach the pipeline.
    def zfs_name(value, label, allow_slash: false)
      pattern = allow_slash ? %r{\A[A-Za-z0-9][A-Za-z0-9_.:/-]*\z} : /\A[A-Za-z0-9][A-Za-z0-9_.:-]*\z/
      unless value.is_a?(String) && value.match?(pattern)
        raise ConfigError,
              "'#{label}' must contain only letters, digits, and _ . : -" \
              "#{' /' if allow_slash} (got #{value.inspect})"
      end
      value
    end

    # mbuffer's -R takes <bytes-per-second> with an optional k/M/G suffix.
    def bwlimit_or_nil(hash)
      return nil unless hash.key?('bwlimit')
      value = hash.fetch('bwlimit')
      value = value.to_s if value.is_a?(Integer) && value.positive?
      unless value.is_a?(String) && value.match?(/\A[1-9]\d*[kKmMgG]?\z/)
        raise ConfigError,
              "'bwlimit' must be a rate like 50m or 800k (digits with an " \
              "optional k/M/G suffix), got #{hash.fetch('bwlimit').inspect}"
      end
      value
    end

    def boolean(hash, key, default)
      return default unless hash.key?(key)
      value = hash.fetch(key)
      unless [true, false].include?(value)
        raise ConfigError, "'#{key}' must be true or false"
      end
      value
    end

    def positive_int(hash, key, default)
      return default unless hash.key?(key)
      value = hash.fetch(key)
      unless value.is_a?(Integer) && value.positive?
        raise ConfigError, "'#{key}' must be a positive integer"
      end
      value
    end

    def non_negative_int(hash, key, default)
      return default unless hash.key?(key)
      value = hash.fetch(key)
      unless value.is_a?(Integer) && value >= 0
        raise ConfigError, "'#{key}' must be a non-negative integer"
      end
      value
    end

    def positive_int_or_nil(hash, key)
      return nil unless hash.key?(key)
      value = hash.fetch(key)
      unless value.is_a?(Integer) && value.positive?
        raise ConfigError, "'#{key}' must be a positive integer"
      end
      value
    end

    def parse_concurrency(hash, key, default)
      return default unless hash.key?(key)
      value = hash.fetch(key)
      unless value.is_a?(Integer) && value >= 1
        raise ConfigError, "'#{key}' must be a positive integer"
      end
      value
    end
  end
end
