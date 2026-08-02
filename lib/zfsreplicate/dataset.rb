# frozen_string_literal: true
# lib/zfsreplicate/dataset.rb
require_relative 'snapshot'
require_relative 'executor'

module ZFSReplicate
  class Dataset
    attr_reader :name

    def initialize(name, executor:)
      @name = name
      @executor = executor
    end

    def exists?
      @executor.run("zfs list -H -o name #{@name}")
      true
    rescue ExecutorError
      false
    end

    def resume_token
      value = @executor.run("zfs get -H -o value receive_resume_token #{@name}").strip
      value.empty? || value == '-' ? nil : value
    rescue ExecutorError
      nil
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

    def create_snapshot(tag, recursive: false)
      @executor.run("zfs snapshot#{' -r' if recursive} #{@name}@#{tag}")
    end

    def destroy_snapshot(tag, recursive: false)
      @executor.run("zfs destroy#{' -r' if recursive} #{@name}@#{tag}")
    end
  end
end
