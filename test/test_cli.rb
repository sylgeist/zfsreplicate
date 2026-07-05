# test/test_cli.rb
require 'test_helper'
require 'zfsreplicate/cli'
require 'zfsreplicate/job_runner'
require 'zfsreplicate/replicator'
require 'tmpdir'

class TestCLIParsing < Minitest::Test
  def test_help_exits_zero
    ex = nil
    assert_output(/Usage:/) do
      ex = assert_raises(SystemExit) { ZFSReplicate::CLI.run(['help']) }
    end
    assert_equal 0, ex.status
  end

  def test_unknown_subcommand_exits_two
    ex = nil
    assert_output(nil, /Unknown command/) do
      ex = assert_raises(SystemExit) { ZFSReplicate::CLI.run(['bogus']) }
    end
    assert_equal 2, ex.status
  end

  def test_no_args_prints_usage_and_exits_two
    ex = nil
    assert_output(/Usage:/) do
      ex = assert_raises(SystemExit) { ZFSReplicate::CLI.run([]) }
    end
    assert_equal 2, ex.status
  end

  def test_version_flag_prints_version_and_exits_zero
    ex = nil
    assert_output(/\d+\.\d+\.\d+/) do
      ex = assert_raises(SystemExit) { ZFSReplicate::CLI.run(['--version']) }
    end
    assert_equal 0, ex.status
  end

  def test_exit_code_for_all_ok
    results = [ZFSReplicate::JobResult.new('a', :ok, 1.0, nil)]
    assert_equal 0, ZFSReplicate::CLI.exit_code_for(results)
  end

  def test_exit_code_for_with_failure
    results = [ZFSReplicate::JobResult.new('a', :ok, 1.0, nil),
               ZFSReplicate::JobResult.new('b', :failed, 1.0, 'x')]
    assert_equal 1, ZFSReplicate::CLI.exit_code_for(results)
  end

  def test_skipped_does_not_cause_failure_exit
    results = [ZFSReplicate::JobResult.new('a', :skipped, 0.0, nil)]
    assert_equal 0, ZFSReplicate::CLI.exit_code_for(results)
  end

  def test_invalid_concurrency_exits_two
    ex = nil
    assert_output(nil, /concurrency/) do
      ex = assert_raises(SystemExit) { ZFSReplicate::CLI.run(['-j', '0', 'sync']) }
    end
    assert_equal 2, ex.status
  end

  def test_lock_filename_sanitizes
    assert_equal 'prod_pool', ZFSReplicate::CLI.lock_filename('prod/pool')
    assert_equal 'a.b-c_1', ZFSReplicate::CLI.lock_filename('a.b-c_1')
  end

  # --lock-dir overrides the config's lock_dir. The config points lock_dir at a
  # path that cannot be created (a directory under a regular file); without the
  # flag override, mkdir_p would fail and the run would exit 2. With the flag,
  # the run succeeds and the lock file lands in the flag's directory.
  def test_lock_dir_flag_overrides_config
    Dir.mktmpdir do |dir|
      blocker = File.join(dir, 'blocker')
      File.write(blocker, 'x')
      bad_lock_dir = File.join(blocker, 'locks') # mkdir_p here raises ENOTDIR
      good_lock_dir = File.join(dir, 'good-locks')
      cfg = File.join(dir, 'c.yml')
      File.write(cfg, <<~YAML)
        lock_dir: #{bad_lock_dir}
        replications:
          - name: job-a
            source: { dataset: tank/a }
            destination: { dataset: backup/a }
      YAML

      ZFSReplicate::Replicator.define_method(:run) { nil } # succeed, no real zfs
      ex = nil
      capture_io do
        ex = assert_raises(SystemExit) do
          ZFSReplicate::CLI.run(['-c', cfg, '--lock-dir', good_lock_dir, 'sync'])
        end
      end
      assert_equal 0, ex.status
      assert File.exist?(File.join(good_lock_dir, 'job-a.lock')),
             'lock file should be created in the --lock-dir directory'
    end
  ensure
    load 'zfsreplicate/replicator.rb'
  end
end
