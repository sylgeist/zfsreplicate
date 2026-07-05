# frozen_string_literal: true
require 'fileutils'

module ZFSReplicate
  # Non-blocking advisory lock, one file per job name. A run whose lock is
  # already held by another process/thread is skipped rather than blocked.
  class Lock
    SKIPPED = :skipped

    def self.acquire(name, dir:)
      FileUtils.mkdir_p(dir)
      file = File.open(File.join(dir, "#{name}.lock"), File::CREAT | File::RDWR, 0o644)
      if file.flock(File::LOCK_EX | File::LOCK_NB)
        begin
          yield
        ensure
          file.flock(File::LOCK_UN)
          file.close
        end
      else
        file.close
        SKIPPED
      end
    end
  end
end
