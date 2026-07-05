require 'test_helper'
require 'zfsreplicate/lock'
require 'tmpdir'

class TestLock < Minitest::Test
  def test_acquire_yields_and_returns_block_value
    Dir.mktmpdir do |dir|
      result = ZFSReplicate::Lock.acquire('job-a', dir: dir) { :did_work }
      assert_equal :did_work, result
      assert File.exist?(File.join(dir, 'job-a.lock'))
    end
  end

  def test_creates_missing_dir
    Dir.mktmpdir do |base|
      dir = File.join(base, 'nested', 'locks')
      ran = false
      ZFSReplicate::Lock.acquire('job-a', dir: dir) { ran = true }
      assert ran
      assert Dir.exist?(dir)
    end
  end

  def test_skips_when_already_held
    Dir.mktmpdir do |dir|
      held = File.open(File.join(dir, 'job-a.lock'), File::CREAT | File::RDWR, 0o644)
      held.flock(File::LOCK_EX | File::LOCK_NB)
      begin
        ran = false
        result = ZFSReplicate::Lock.acquire('job-a', dir: dir) { ran = true }
        assert_equal ZFSReplicate::Lock::SKIPPED, result
        refute ran, 'block must not run while lock is held'
      ensure
        held.flock(File::LOCK_UN)
        held.close
      end
    end
  end

  def test_lock_released_after_block
    Dir.mktmpdir do |dir|
      ZFSReplicate::Lock.acquire('job-a', dir: dir) { :first }
      # second acquire should succeed now that the first released
      result = ZFSReplicate::Lock.acquire('job-a', dir: dir) { :second }
      assert_equal :second, result
    end
  end

  def test_uncreatable_dir_raises
    Dir.mktmpdir do |base|
      blocker = File.join(base, 'not-a-dir')
      File.write(blocker, 'x')                 # a file, not a dir
      bad_dir = File.join(blocker, 'locks')    # can't mkdir under a file
      assert_raises(SystemCallError) do
        ZFSReplicate::Lock.acquire('job-a', dir: bad_dir) { :nope }
      end
    end
  end
end
