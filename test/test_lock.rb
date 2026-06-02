# frozen_string_literal: true
require 'test_helper'
require 'zfsreplicate/lock'
require 'tmpdir'
require 'fileutils'

class TestLock < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @path = File.join(@dir, 'job.lock')
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_acquire_succeeds_when_free
    lock = ZFSReplicate::Lock.new(@path)
    assert lock.acquire
    lock.release
  end

  def test_second_acquire_fails_while_held
    a = ZFSReplicate::Lock.new(@path)
    b = ZFSReplicate::Lock.new(@path)
    assert a.acquire
    refute b.acquire
    a.release
  end

  def test_acquire_succeeds_after_release
    a = ZFSReplicate::Lock.new(@path)
    b = ZFSReplicate::Lock.new(@path)
    assert a.acquire
    a.release
    assert b.acquire
    b.release
  end

  def test_double_acquire_on_same_instance_is_safe
    lock = ZFSReplicate::Lock.new(@path)
    assert lock.acquire
    assert lock.acquire        # release-then-reacquire; no leaked fd
    lock.release
    # lock fully released: a different instance can now acquire it
    other = ZFSReplicate::Lock.new(@path)
    assert other.acquire
    other.release
  end
end
