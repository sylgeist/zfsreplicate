# frozen_string_literal: true
# lib/zfsreplicate/config.rb
require 'yaml'

module ZFSReplicate
  class ConfigError < StandardError; end

  EndpointConfig = Struct.new(:host, :user, :dataset, :port, :identity) do
    def local?
      host.nil?
    end
  end

  ReplicationConfig = Struct.new(
    :name, :source, :destination, :recursive, :keep_snapshots, :snapshot_prefix,
    :force, :resume, :max_retries, :retry_delay
  )

  class Config
    attr_reader :replications

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
    end

    private

    def parse_replication(r)
      raise ConfigError, "Each replication must be a mapping" unless r.is_a?(Hash)
      ReplicationConfig.new(
        require_key(r, 'name'),
        parse_endpoint(require_key(r, 'source'), 'source'),
        parse_endpoint(require_key(r, 'destination'), 'destination'),
        r.fetch('recursive', false),
        r.fetch('keep_snapshots', 7),
        r.fetch('snapshot_prefix', 'zfsreplicate'),
        r.fetch('force', false),
        r.fetch('resume', true),
        non_negative_int(r, 'max_retries', 3),
        non_negative_int(r, 'retry_delay', 5)
      )
    end

    def parse_endpoint(e, role)
      raise ConfigError, "'#{role}' must be a mapping" unless e.is_a?(Hash)
      EndpointConfig.new(
        e['host'],
        e.fetch('user', 'root'),
        require_key(e, 'dataset', "#{role}.dataset"),
        e.fetch('port', 22),
        e['identity']
      )
    end

    def require_key(hash, key, label = key)
      raise ConfigError, "Missing required '#{label}' in replication config" unless hash.key?(key)
      hash.fetch(key)
    end

    def non_negative_int(hash, key, default)
      return default unless hash.key?(key)
      value = hash.fetch(key)
      unless value.is_a?(Integer) && value >= 0
        raise ConfigError, "'#{key}' must be a non-negative integer"
      end
      value
    end
  end
end
