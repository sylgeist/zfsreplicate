# frozen_string_literal: true
# lib/zfsreplicate/config.rb
require 'yaml'
require 'tmpdir'

module ZFSReplicate
  class ConfigError < StandardError; end

  EndpointConfig = Struct.new(:host, :user, :dataset, :port, :identity) do
    def local?
      host.nil?
    end
  end

  ReplicationConfig = Struct.new(
    :name, :source, :destination, :recursive, :keep_snapshots, :snapshot_prefix,
    :force, :resume, :max_retries, :retry_delay, :compressed_send, :bwlimit, :timeout
  )

  class Config
    DEFAULT_LOCK_DIR = File.join(Dir.tmpdir, 'zfsreplicate-locks')

    attr_reader :replications, :concurrency, :lock_dir

    def self.load(path)
      raise ConfigError, "Config file not found: #{path}" unless File.exist?(path)
      raw = YAML.safe_load(File.read(path), permitted_classes: [])
      raise ConfigError, "Missing 'replications' key in #{path}" unless raw.is_a?(Hash) && raw.key?('replications')
      new(raw)
    end

    def initialize(raw)
      list = raw.fetch('replications')
      raise ConfigError, "'replications' must be a list" unless list.is_a?(Array)
      @replications = list.map { |r| parse_replication(r) }
      @concurrency = parse_concurrency(raw, 'concurrency', 1)
      @lock_dir = raw.fetch('lock_dir', DEFAULT_LOCK_DIR)
    end

    private

    def parse_replication(r)
      raise ConfigError, "Each replication must be a mapping" unless r.is_a?(Hash)
      ReplicationConfig.new(
        require_key(r, 'name'),
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
        positive_int_or_nil(r, 'timeout')
      )
    end

    def parse_endpoint(e, role)
      raise ConfigError, "'#{role}' must be a mapping" unless e.is_a?(Hash)
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
      unless value.is_a?(String) && value.match?(/\A\d+[kKmMgG]?\z/)
        raise ConfigError,
              "'bwlimit' must be a rate like 50m or 800k (digits with an " \
              "optional k/M/G suffix), got #{hash.fetch('bwlimit').inspect}"
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
