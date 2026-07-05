# test/test_cli.rb
require 'test_helper'
require 'zfsreplicate/cli'

class TestCLIParsing < Minitest::Test
  def test_help_exits_zero
    ex = nil
    assert_output(/Usage:/) do
      ex = assert_raises(SystemExit) { ZFSReplicate::CLI.run(['help']) }
    end
    assert_equal 0, ex.status
  end

  def test_unknown_subcommand_exits_nonzero
    assert_raises(SystemExit) do
      ZFSReplicate::CLI.run(['bogus'])
    end
  end

  def test_no_args_prints_usage_and_exits_nonzero
    assert_raises(SystemExit) { ZFSReplicate::CLI.run([]) }
  end

  def test_version_flag_prints_version_and_exits_zero
    ex = nil
    assert_output(/\d+\.\d+\.\d+/) do
      ex = assert_raises(SystemExit) { ZFSReplicate::CLI.run(['--version']) }
    end
    assert_equal 0, ex.status
  end
end

require 'tmpdir'
require 'fileutils'

class TestCLISync < Minitest::Test
  # Minimal config with one local->local job (no real ZFS is invoked because
  # we stub Replicator#run).
  CONFIG = <<~YAML
    replications:
      - name: job-a
        source: { dataset: tank/a }
        destination: { dataset: backup/a }
      - name: job-b
        source: { dataset: tank/b }
        destination: { dataset: backup/b }
  YAML

  def with_config
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'c.yml')
      File.write(path, CONFIG)
      lock_dir = File.join(dir, 'locks')
      yield path, lock_dir
    end
  end

  def test_all_ok_exits_zero
    with_config do |path, lock_dir|
      ZFSReplicate::Replicator.define_method(:run) { nil } # succeed
      ex = assert_raises(SystemExit) do
        ZFSReplicate::CLI.run(['-c', path, '--lock-dir', lock_dir, 'sync'])
      end
      assert_equal 0, ex.status
    end
  ensure
    load 'zfsreplicate/replicator.rb'
  end

  def test_one_failure_exits_one
    with_config do |path, lock_dir|
      ZFSReplicate::Replicator.define_method(:run) do
        raise ZFSReplicate::ExecutorError, 'boom' if @cfg.name == 'job-b'
      end
      ex = assert_raises(SystemExit) do
        ZFSReplicate::CLI.run(['-c', path, '--lock-dir', lock_dir, 'sync'])
      end
      assert_equal 1, ex.status
    end
  ensure
    load 'zfsreplicate/replicator.rb'
  end

  def test_skipped_lock_held_job_exits_zero
    with_config do |path, lock_dir|
      ZFSReplicate::Replicator.define_method(:run) { nil } # all jobs succeed if reached
      FileUtils.mkdir_p(lock_dir)
      lock_fd = File.open(File.join(lock_dir, 'job-a.lock'), File::CREAT | File::RDWR, 0o644)
      lock_fd.flock(File::LOCK_EX | File::LOCK_NB)
      begin
        ex = assert_raises(SystemExit) do
          ZFSReplicate::CLI.run(['-c', path, '--lock-dir', lock_dir, 'sync'])
        end
        assert_equal 0, ex.status
      ensure
        lock_fd.flock(File::LOCK_UN)
        lock_fd.close
      end
    end
  ensure
    load 'zfsreplicate/replicator.rb'
  end

  def test_config_error_exits_two
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'bad.yml')
      File.write(path, "not_replications: {}\n")
      ex = assert_raises(SystemExit) { ZFSReplicate::CLI.run(['-c', path, 'sync']) }
      assert_equal 2, ex.status
    end
  end
end
