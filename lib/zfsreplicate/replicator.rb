# frozen_string_literal: true
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

    # Guard against a destructive full send. A full `zfs send | zfs recv -F`
    # overwrites the destination, so refuse it when there is no common snapshot
    # AND the destination already exists — unless the user opts in with force.
    def self.guard_full_send!(destination:, common:, destination_exists:, force:)
      return if common              # incremental — safe
      return if force               # explicit override
      return unless destination_exists # fresh target — safe to create
      raise ExecutorError,
            "Destination #{destination} already exists but shares no snapshot " \
            "with the source; refusing full send with -F (would overwrite it). " \
            "Destroy the destination and re-run, or set force: true."
    end

    # Instance interface for running a full replication job. Executors may be
    # injected (for testing); otherwise they are built from the endpoint config.
    def initialize(replication_config, src_executor: nil, dst_executor: nil)
      @cfg = replication_config
      @src_executor = src_executor
      @dst_executor = dst_executor
    end

    def run
      src_exec = @src_executor || executor_for(@cfg.source)
      dst_exec = @dst_executor || executor_for(@cfg.destination)

      unless @cfg.source.local? || @cfg.destination.local?
        ZFSReplicate.logger.info(
          "Both endpoints are remote; the stream is relayed through this host " \
          "(source -> here -> destination)"
        )
      end

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

      self.class.guard_full_send!(
        destination: @cfg.destination.dataset,
        common: common,
        destination_exists: common.nil? && dst_ds.exists?,
        force: @cfg.force
      )

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
      return Executor.local if endpoint.local?
      Executor.remote(host: endpoint.host, user: endpoint.user,
                      port: endpoint.port, identity: endpoint.identity)
    end

    def remote_recv_cmd(dst_exec, recv_cmd)
      dst_exec.local? ? recv_cmd : "#{dst_exec.ssh_prefix} #{Shellwords.escape(recv_cmd)}"
    end
  end
end
