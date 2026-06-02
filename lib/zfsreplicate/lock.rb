# frozen_string_literal: true

module ZFSReplicate
  # Non-blocking advisory lock over a per-job file. flock is held by the OS on
  # the open file descriptor and auto-releases when the fd closes or the process
  # dies, so it guards against overlapping runs across separate processes (cron)
  # and leaves no stale state on crash.
  class Lock
    def initialize(path)
      @path = path
    end

    def acquire
      release
      @file = File.open(@path, File::CREAT | File::RDWR, 0o644)
      # flock returns 0 on success (truthy) or false if the lock is held.
      !!@file.flock(File::LOCK_EX | File::LOCK_NB)
    rescue SystemCallError
      false
    end

    def release
      return unless @file
      @file.flock(File::LOCK_UN)
      @file.close
      @file = nil
    end
  end
end
