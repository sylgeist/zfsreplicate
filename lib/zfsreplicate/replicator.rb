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

    def self.send_command(latest:, common:, recursive:, compressed:)
      flags = +''
      flags << ' -R' if recursive
      flags << ' -c' if compressed
      if common
        "zfs send#{flags} -I #{common.dataset}@#{common.tag} #{latest.dataset}@#{latest.tag}"
      else
        "zfs send#{flags} #{latest.dataset}@#{latest.tag}"
      end
    end

    def self.resume_send_command(token:)
      "zfs send -t #{token}"
    end

    def self.recv_command(dataset:, fresh:, resumable:)
      parts = ['zfs recv']
      parts << '-F' if fresh
      parts << '-s' if resumable
      parts << dataset
      parts.join(' ')
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
    def initialize(replication_config, src_executor: nil, dst_executor: nil,
                   sleeper: ->(s) { Kernel.sleep(s) })
      @cfg = replication_config
      @src_executor = src_executor
      @dst_executor = dst_executor
      @sleeper = sleeper
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

      recv_resume = self.class.recv_command(dataset: @cfg.destination.dataset,
                                            fresh: false, resumable: true)

      if @cfg.resume && dst_ds.resume_token
        ZFSReplicate.logger.info(
          "Resuming interrupted transfer to #{@cfg.destination.dataset}"
        )
        perform_transfer(
          src_exec, dst_exec, dst_ds,
          fresh_send: nil, recv_fresh: nil, recv_resume: recv_resume
        )
      end

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

      fresh_send = self.class.send_command(latest: latest, common: common,
                                           recursive: @cfg.recursive,
                                           compressed: @cfg.compressed_send)
      recv_fresh = self.class.recv_command(dataset: @cfg.destination.dataset,
                                           fresh: true, resumable: @cfg.resume)

      ZFSReplicate.logger.info("Sending #{latest.tag} (#{common ? 'incremental' : 'full'})")
      perform_transfer(src_exec, dst_exec, dst_ds,
                       fresh_send: fresh_send, recv_fresh: recv_fresh,
                       recv_resume: recv_resume)

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

    def perform_transfer(src_exec, dst_exec, dst_ds, fresh_send:, recv_fresh:, recv_resume:)
      attempt = 0
      loop do
        token = @cfg.resume ? dst_ds.resume_token : nil
        if token
          send_cmd = self.class.resume_send_command(token: token)
          recv_cmd = recv_resume
        elsif fresh_send
          send_cmd = fresh_send
          recv_cmd = recv_fresh
        else
          return
        end

        begin
          src_exec.run_pipeline(send_cmd, remote_recv_cmd(dst_exec, recv_cmd))
          return
        rescue ExecutorError => e
          attempt += 1
          raise if !@cfg.resume || attempt > @cfg.max_retries
          delay = @cfg.retry_delay * (2**(attempt - 1))
          ZFSReplicate.logger.warn(
            "Transfer attempt #{attempt} failed (#{e.message}); retrying in #{delay}s"
          )
          @sleeper.call(delay)
        end
      end
    end

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
