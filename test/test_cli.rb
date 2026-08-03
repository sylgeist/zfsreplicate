# test/test_cli.rb
require 'test_helper'
require 'zfsreplicate/cli'
require 'zfsreplicate/job_runner'
require 'zfsreplicate/replicator'
require 'tmpdir'

class TestCLIParsing < Minitest::Test
  # FreeBSD convention for third-party tools: config under /usr/local/etc.
  def test_default_config_is_freebsd_traditional
    assert_equal '/usr/local/etc/zfsreplicate/config.yml',
                 ZFSReplicate::CLI::DEFAULT_CONFIG
  end

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
  def rep(name, src_host: nil, dst_host: nil)
    ZFSReplicate::ReplicationConfig.new(
      name,
      ZFSReplicate::EndpointConfig.new(src_host, 'root', "tank/#{name}", 22, nil),
      ZFSReplicate::EndpointConfig.new(dst_host, 'root', "backup/#{name}", 22, nil),
      false, 7, 'zfsreplicate', false, true, 3, 5, true, nil, nil
    )
  end

  def fleet
    [rep('rhea-ca', dst_host: 'rhea.risei.net'),
     rep('rhea-git', dst_host: 'rhea.risei.net'),
     rep('rhea-root', src_host: 'rhea.risei.net'),
     rep('io-git', dst_host: 'io.risei.net'),
     rep('local-home')]
  end

  # Disabled jobs are benched, not deleted: excluded from every implicit
  # selection (bare sync, globs, --host), but an exact name still runs them so
  # a benched job can be tested without editing the config back and forth.
  def test_select_jobs_excludes_disabled_from_implicit_selection
    jobs = fleet
    jobs[0].enabled = false # rhea-ca
    assert_equal %w[rhea-git rhea-root io-git local-home],
                 ZFSReplicate::CLI.select_jobs(jobs, names: [], host: nil).map(&:name)
    assert_equal %w[rhea-git rhea-root],
                 ZFSReplicate::CLI.select_jobs(jobs, names: ['rhea-*'], host: nil).map(&:name)
    assert_equal %w[rhea-git rhea-root],
                 ZFSReplicate::CLI.select_jobs(jobs, names: [], host: 'rhea.risei.net').map(&:name)
  end

  def test_select_jobs_exact_name_runs_a_disabled_job
    jobs = fleet
    jobs[0].enabled = false # rhea-ca
    picked = ZFSReplicate::CLI.select_jobs(jobs, names: ['rhea-ca'], host: nil)
    assert_equal ['rhea-ca'], picked.map(&:name)
  end

  def test_list_marks_disabled_jobs
    Dir.mktmpdir do |dir|
      cfg = File.join(dir, 'c.yml')
      File.write(cfg, <<~YAML)
        replications:
          - name: benched
            enabled: false
            source: { dataset: tank/a }
            destination: { dataset: backup/a }
          - name: live
            source: { dataset: tank/b }
            destination: { dataset: backup/b }
      YAML
      out, = capture_io { ZFSReplicate::CLI.run(['-c', cfg, 'list']) }
      assert_match(/benched:.*\(disabled\)/, out)
      refute_match(/live:.*disabled/, out)
    end
  end

  def test_select_jobs_exact_name
    picked = ZFSReplicate::CLI.select_jobs(fleet, names: ['io-git'], host: nil)
    assert_equal ['io-git'], picked.map(&:name)
  end

  def test_select_jobs_glob
    picked = ZFSReplicate::CLI.select_jobs(fleet, names: ['rhea-*'], host: nil)
    assert_equal %w[rhea-ca rhea-git rhea-root], picked.map(&:name)
  end

  def test_select_jobs_multiple_names_union
    picked = ZFSReplicate::CLI.select_jobs(fleet, names: %w[io-git local-home], host: nil)
    assert_equal %w[io-git local-home], picked.map(&:name)
  end

  def test_select_jobs_by_host_matches_either_endpoint
    picked = ZFSReplicate::CLI.select_jobs(fleet, names: [], host: 'rhea.risei.net')
    assert_equal %w[rhea-ca rhea-git rhea-root], picked.map(&:name),
                 'host filter must match source or destination endpoints'
  end

  def test_select_jobs_host_glob
    picked = ZFSReplicate::CLI.select_jobs(fleet, names: [], host: '*.risei.net')
    assert_equal %w[rhea-ca rhea-git rhea-root io-git], picked.map(&:name)
  end

  def test_select_jobs_names_and_host_intersect
    picked = ZFSReplicate::CLI.select_jobs(fleet, names: ['*-git'], host: 'rhea.risei.net')
    assert_equal ['rhea-git'], picked.map(&:name)
  end

  # --force must always say what it is forcing: with no selection it would arm
  # the overwrite on every configured job at once.
  def test_force_without_selection_exits_two
    ex = nil
    assert_output(nil, /--force requires/) do
      ex = assert_raises(SystemExit) { ZFSReplicate::CLI.run(['--force', 'sync']) }
    end
    assert_equal 2, ex.status
  end

  def test_force_applies_only_to_selected_jobs_for_this_run
    Dir.mktmpdir do |dir|
      cfg = File.join(dir, 'c.yml')
      File.write(cfg, <<~YAML)
        replications:
          - name: rhea-ca
            source: { dataset: tank/CA }
            destination: { host: rhea.risei.net, dataset: backup/CA }
      YAML
      out, = capture_io do
        ZFSReplicate::CLI.run(['-c', cfg, '-n', '--force', 'sync', 'rhea-*'])
      end
      assert_includes out, '(forced)'
      # A plain run of the same config is not forced — the flag is one-shot.
      out, = capture_io do
        ZFSReplicate::CLI.run(['-c', cfg, '-n', 'sync', 'rhea-*'])
      end
      refute_includes out, '(forced)'
    end
  end

  def test_sync_glob_dry_run_and_no_match_exit
    Dir.mktmpdir do |dir|
      cfg = File.join(dir, 'c.yml')
      File.write(cfg, <<~YAML)
        replications:
          - name: rhea-ca
            source: { dataset: tank/CA }
            destination: { host: rhea.risei.net, dataset: backup/CA }
          - name: io-git
            source: { dataset: tank/Git }
            destination: { host: io.risei.net, dataset: backup/Git }
      YAML
      out, = capture_io do
        ZFSReplicate::CLI.run(['-c', cfg, '-n', 'sync', 'rhea-*'])
      end
      assert_includes out, 'tank/CA'
      refute_includes out, 'tank/Git'

      out, = capture_io do
        ZFSReplicate::CLI.run(['-c', cfg, '-n', '--host', 'rhea.risei.net', 'sync'])
      end
      assert_includes out, 'tank/CA'
      refute_includes out, 'tank/Git'

      ex = nil
      capture_io do
        ex = assert_raises(SystemExit) do
          ZFSReplicate::CLI.run(['-c', cfg, '-n', 'sync', 'nope-*'])
        end
      end
      assert_equal 2, ex.status
    end
  end

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
