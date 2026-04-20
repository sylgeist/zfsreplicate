# lib/zfsreplicate/replicator.rb
require 'set'
require 'shellwords'
require_relative 'log'
require_relative 'snapshot'
require_relative 'dataset'
require_relative 'executor'

module ZFSReplicate
  class Replicator
    # Pure helper: latest tag shared between src and dst snapshot arrays.
    def self.common_snapshot(src_snaps, dst_snaps)
      dst_tags = dst_snaps.map(&:tag).to_set
      src_snaps.select { |s| dst_tags.include?(s.tag) }.max
    end

    def self.send_command(latest:, common:, recursive:)
      flags = recursive ? ' -R' : ''
      if common
        "zfs send#{flags} -I #{common.dataset}@#{common.tag} #{latest.dataset}@#{latest.tag}"
      else
        "zfs send#{flags} #{latest.dataset}@#{latest.tag}"
      end
    end

    def self.snapshots_to_prune(snaps, keep:)
      sorted = snaps.sort
      sorted.length > keep ? sorted[0...(sorted.length - keep)] : []
    end

    # Instance interface for running a full replication job.
    def initialize(replication_config)
      @cfg = replication_config
    end

    def run
      src_exec = executor_for(@cfg.source)
      dst_exec = executor_for(@cfg.destination)

      src_ds = Dataset.new(@cfg.source.dataset, executor: src_exec)
      dst_ds = Dataset.new(@cfg.destination.dataset, executor: dst_exec)

      tag = Snapshot.generate_name(@cfg.source.dataset,
                                   prefix: @cfg.snapshot_prefix).split('@').last
      ZFSReplicate.logger.info("Creating snapshot #{@cfg.source.dataset}@#{tag}")
      src_ds.create_snapshot(tag)

      src_snaps = src_ds.managed_snapshots(prefix: @cfg.snapshot_prefix)
      dst_snaps = dst_ds.managed_snapshots(prefix: @cfg.snapshot_prefix)
      latest    = src_snaps.max
      common    = self.class.common_snapshot(src_snaps, dst_snaps)

      if common.nil? && !dst_snaps.empty?
        raise "No common snapshot between source and destination — manual intervention required"
      end

      send_cmd = self.class.send_command(latest: latest, common: common,
                                         recursive: @cfg.recursive)
      recv_cmd = "zfs recv -F #{@cfg.destination.dataset}"

      ZFSReplicate.logger.info("Sending #{latest.tag} (#{common ? 'incremental' : 'full'})")
      src_exec.run_pipeline(send_cmd, remote_recv_cmd(dst_exec, recv_cmd))

      prune_source = self.class.snapshots_to_prune(src_snaps, keep: @cfg.keep_snapshots)
      prune_source.each do |snap|
        ZFSReplicate.logger.info("Pruning source #{snap.tag}")
        src_ds.destroy_snapshot(snap.tag)
      end

      prune_dest = self.class.snapshots_to_prune(
        dst_ds.managed_snapshots(prefix: @cfg.snapshot_prefix),
        keep: @cfg.keep_snapshots
      )
      prune_dest.each do |snap|
        ZFSReplicate.logger.info("Pruning destination #{snap.tag}")
        dst_ds.destroy_snapshot(snap.tag)
      end
    end

    private

    def executor_for(endpoint)
      endpoint.local? ? Executor.local : Executor.remote(host: endpoint.host,
                                                          user: endpoint.user,
                                                          port: endpoint.port)
    end

    def remote_recv_cmd(dst_exec, recv_cmd)
      dst_exec.local? ? recv_cmd : "#{dst_exec.ssh_prefix} #{Shellwords.escape(recv_cmd)}"
    end
  end
end
