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
    rescue ExecutorError => e
      # Only ZFS saying the dataset is missing means "no". Anything else
      # (SSH failure, permissions) must propagate — treating it as absent
      # would let a full send overwrite an existing destination.
      raise unless e.message =~ /dataset does not exist/
      false
    end

    def resume_token
      value = @executor.run("zfs get -H -o value receive_resume_token #{@name}").strip
      value.empty? || value == '-' ? nil : value
    rescue ExecutorError
      nil
    end

    def snapshots
      raw = @executor.run("zfs list -t snapshot -d 1 -H -o name -s creation #{@name}")
      raw.lines.map(&:chomp).reject(&:empty?).map { |l| Snapshot.parse(l) }.sort
    end

    def managed_snapshots(prefix:)
      snapshots.select { |s| s.prefix == prefix }
    end

    def latest_snapshot(prefix:)
      managed_snapshots(prefix: prefix).max
    end

    # Relative paths ('' for this dataset, 'child', 'child/grand') of every
    # dataset in this subtree that holds a snapshot named tag. Used to verify
    # a recursive transfer delivered the whole subtree.
    def descendants_with_snapshot(tag)
      raw = @executor.run("zfs list -t snapshot -r -H -o name #{@name}")
      raw.lines.map(&:chomp).reject(&:empty?).filter_map do |line|
        ds, snap = line.split('@', 2)
        next unless snap == tag
        next unless ds == @name || ds.start_with?("#{@name}/")
        ds.delete_prefix(@name).delete_prefix('/')
      end.uniq
    end

    # Managed snapshot tags per subtree member, keyed by relative path ('' for
    # this dataset). A -R stream lands child-by-child, so after a failed or
    # interrupted run the members can legitimately disagree on their newest
    # tag; this is the input for choosing an incremental base they all hold.
    def managed_tags_by_descendant(prefix:)
      raw = @executor.run("zfs list -t snapshot -r -H -o name #{@name}")
      raw.lines.map(&:chomp).reject(&:empty?).each_with_object({}) do |line, acc|
        ds, = line.split('@', 2)
        next unless ds == @name || ds.start_with?("#{@name}/")
        snap = Snapshot.parse(line)
        next unless snap.prefix == prefix
        (acc[ds.delete_prefix(@name).delete_prefix('/')] ||= []) << snap.tag
      end
    end

    def create_snapshot(tag, recursive: false)
      @executor.run("zfs snapshot#{' -r' if recursive} #{@name}@#{tag}")
    end

    def destroy_snapshot(tag, recursive: false)
      @executor.run("zfs destroy#{' -r' if recursive} #{@name}@#{tag}")
    end
  end
end
