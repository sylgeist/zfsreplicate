# frozen_string_literal: true
require 'fileutils'

module ZFSReplicate
  # Non-blocking advisory lock, one file per job name. A run whose lock is
  # already held by another process/thread is skipped rather than blocked.
  class Lock
    SKIPPED = :skipped

    def self.acquire(name, dir:)
      FileUtils.mkdir_p(dir)
      File.open(File.join(dir, "#{name}.lock"), File::CREAT | File::RDWR, 0o644) do |file|
        # flock returns 0 (truthy) on acquire, false when already held (LOCK_NB)
        if file.flock(File::LOCK_EX | File::LOCK_NB)
          begin
            return yield
          ensure
            file.flock(File::LOCK_UN)
          end
        else
          return SKIPPED
        end
      end
    end
  end
end
