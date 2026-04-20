# lib/zfsreplicate/config.rb
require 'yaml'

module ZFSReplicate
  class ConfigError < StandardError; end

  EndpointConfig = Struct.new(:host, :user, :dataset, :port) do
    def local?
      host.nil?
    end
  end

  ReplicationConfig = Struct.new(
    :name, :source, :destination, :recursive, :keep_snapshots, :snapshot_prefix
  )

  class Config
    attr_reader :replications

    def self.load(path)
      raise ConfigError, "Config file not found: #{path}" unless File.exist?(path)
      raw = YAML.safe_load(File.read(path), permitted_classes: [])
      raise ConfigError, "Missing 'replications' key in #{path}" unless raw.key?('replications')
      new(raw)
    end

    def initialize(raw)
      @replications = raw.fetch('replications').map { |r| parse_replication(r) }
    end

    private

    def parse_replication(r)
      ReplicationConfig.new(
        r['name'],
        parse_endpoint(r.fetch('source')),
        parse_endpoint(r.fetch('destination')),
        r.fetch('recursive', false),
        r.fetch('keep_snapshots', 7),
        r.fetch('snapshot_prefix', 'zfsreplicate')
      )
    end

    def parse_endpoint(e)
      EndpointConfig.new(e['host'], e.fetch('user', 'root'), e.fetch('dataset'), e.fetch('port', 22))
    end
  end
end
