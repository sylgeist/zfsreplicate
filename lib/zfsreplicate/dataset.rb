# lib/zfsreplicate/dataset.rb
require_relative 'snapshot'

module ZFSReplicate
  class Dataset
    attr_reader :name

    def initialize(name, executor:)
      @name = name
      @executor = executor
    end

    def snapshots
      raw = @executor.run("zfs list -t snapshot -H -o name -s creation #{@name}")
      raw.lines.map(&:chomp).reject(&:empty?).map { |l| Snapshot.parse(l) }.sort
    end

    def managed_snapshots(prefix:)
      snapshots.select { |s| s.prefix == prefix }
    end

    def latest_snapshot(prefix:)
      managed_snapshots(prefix: prefix).max
    end

    def create_snapshot(tag)
      @executor.run("zfs snapshot #{@name}@#{tag}")
    end

    def destroy_snapshot(tag)
      @executor.run("zfs destroy #{@name}@#{tag}")
    end
  end
end
