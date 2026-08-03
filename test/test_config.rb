# test/test_config.rb
require 'test_helper'
require 'zfsreplicate/config'
require 'tempfile'

VALID_CONFIG = <<~YAML
  replications:
    - name: vms-backup
      source:
        host: 192.168.1.10
        user: root
        dataset: tank/vms
      destination:
        host: 192.168.1.20
        user: root
        dataset: backup/vms
      recursive: true
      keep_snapshots: 14
      snapshot_prefix: zfsreplicate
YAML

class TestConfig < Minitest::Test
  def write_config(content)
    f = Tempfile.new(['config', '.yml'])
    f.write(content)
    f.flush
    f
  end

  def test_loads_replications
    f = write_config(VALID_CONFIG)
    cfg = ZFSReplicate::Config.load(f.path)
    assert_equal 1, cfg.replications.length
    f.close
  end

  def test_replication_has_source_and_dest
    f = write_config(VALID_CONFIG)
    cfg = ZFSReplicate::Config.load(f.path)
    rep = cfg.replications.first
    assert_equal '192.168.1.10', rep.source.host
    assert_equal 'tank/vms', rep.source.dataset
    assert_equal '192.168.1.20', rep.destination.host
    assert_equal 'backup/vms', rep.destination.dataset
    f.close
  end

  def test_replication_options
    f = write_config(VALID_CONFIG)
    cfg = ZFSReplicate::Config.load(f.path)
    rep = cfg.replications.first
    assert_equal true, rep.recursive
    assert_equal 14, rep.keep_snapshots
    assert_equal 'zfsreplicate', rep.snapshot_prefix
    f.close
  end

  def test_raises_on_missing_file
    assert_raises(ZFSReplicate::ConfigError) do
      ZFSReplicate::Config.load('/nonexistent/path.yml')
    end
  end

  def test_raises_on_missing_replications_key
    f = write_config("nodes: {}\n")
    assert_raises(ZFSReplicate::ConfigError) do
      ZFSReplicate::Config.load(f.path)
    end
    f.close
  end

  def test_local_source_has_nil_host
    yaml = VALID_CONFIG.gsub(/host: 192\.168\.1\.10\n\s+/, '')
    f = write_config(yaml)
    cfg = ZFSReplicate::Config.load(f.path)
    assert_nil cfg.replications.first.source.host
    f.close
  end

  def test_raises_config_error_on_missing_source
    f = write_config("replications:\n  - name: x\n    destination:\n      dataset: d\n")
    err = assert_raises(ZFSReplicate::ConfigError) { ZFSReplicate::Config.load(f.path) }
    assert_match(/source/, err.message)
    f.close
  end

  def test_raises_config_error_on_missing_dataset
    f = write_config("replications:\n  - name: x\n    source:\n      host: h\n    destination:\n      dataset: d\n")
    err = assert_raises(ZFSReplicate::ConfigError) { ZFSReplicate::Config.load(f.path) }
    assert_match(/dataset/, err.message)
    f.close
  end

  def test_raises_config_error_on_missing_name
    f = write_config("replications:\n  - source:\n      dataset: s\n    destination:\n      dataset: d\n")
    err = assert_raises(ZFSReplicate::ConfigError) { ZFSReplicate::Config.load(f.path) }
    assert_match(/name/, err.message)
    f.close
  end

  def test_replications_must_be_a_list
    f = write_config("replications: not-a-list\n")
    assert_raises(ZFSReplicate::ConfigError) { ZFSReplicate::Config.load(f.path) }
    f.close
  end

  def test_parses_identity_field
    yaml = VALID_CONFIG.sub("dataset: tank/vms", "dataset: tank/vms\n      identity: /root/.ssh/repl_key")
    f = write_config(yaml)
    cfg = ZFSReplicate::Config.load(f.path)
    assert_equal '/root/.ssh/repl_key', cfg.replications.first.source.identity
    f.close
  end

  def test_identity_defaults_to_nil
    f = write_config(VALID_CONFIG)
    cfg = ZFSReplicate::Config.load(f.path)
    assert_nil cfg.replications.first.source.identity
    f.close
  end

  def test_force_defaults_to_false
    f = write_config(VALID_CONFIG)
    cfg = ZFSReplicate::Config.load(f.path)
    assert_equal false, cfg.replications.first.force
    f.close
  end

  def test_resume_defaults_true
    f = write_config(VALID_CONFIG)
    cfg = ZFSReplicate::Config.load(f.path)
    assert_equal true, cfg.replications.first.resume
    f.close
  end

  def test_max_retries_default
    f = write_config(VALID_CONFIG)
    rep = ZFSReplicate::Config.load(f.path).replications.first
    assert_equal 3, rep.max_retries
    f.close
  end

  def test_retry_delay_default
    f = write_config(VALID_CONFIG)
    rep = ZFSReplicate::Config.load(f.path).replications.first
    assert_equal 5, rep.retry_delay
    f.close
  end

  def test_resume_can_be_disabled
    f = write_config(VALID_CONFIG + "    resume: false\n")
    rep = ZFSReplicate::Config.load(f.path).replications.first
    assert_equal false, rep.resume
    f.close
  end

  def test_rejects_negative_max_retries
    f = write_config(VALID_CONFIG + "    max_retries: -1\n")
    err = assert_raises(ZFSReplicate::ConfigError) { ZFSReplicate::Config.load(f.path) }
    assert_match(/max_retries/, err.message)
    f.close
  end

  def test_rejects_non_integer_retry_delay
    f = write_config(VALID_CONFIG + "    retry_delay: fast\n")
    err = assert_raises(ZFSReplicate::ConfigError) { ZFSReplicate::Config.load(f.path) }
    assert_match(/retry_delay/, err.message)
    f.close
  end

  def test_concurrency_defaults_to_one
    f = write_config(VALID_CONFIG)
    assert_equal 1, ZFSReplicate::Config.load(f.path).concurrency
    f.close
  end

  def test_parses_concurrency
    f = write_config(VALID_CONFIG + "concurrency: 4\n")
    assert_equal 4, ZFSReplicate::Config.load(f.path).concurrency
    f.close
  end

  def test_rejects_non_positive_concurrency
    ['concurrency: 0', 'concurrency: -3'].each do |bad|
      f = write_config(VALID_CONFIG + bad + "\n")
      err = assert_raises(ZFSReplicate::ConfigError) { ZFSReplicate::Config.load(f.path) }
      assert_match(/concurrency/, err.message)
      f.close
    end
  end

  def test_lock_dir_has_default
    f = write_config(VALID_CONFIG)
    assert_equal ZFSReplicate::Config::DEFAULT_LOCK_DIR,
                 ZFSReplicate::Config.load(f.path).lock_dir
    f.close
  end

  def test_parses_lock_dir
    f = write_config(VALID_CONFIG + "lock_dir: /var/lock/zr\n")
    assert_equal '/var/lock/zr', ZFSReplicate::Config.load(f.path).lock_dir
    f.close
  end

  def test_compressed_send_defaults_true
    f = write_config(VALID_CONFIG)
    assert_equal true, ZFSReplicate::Config.load(f.path).replications.first.compressed_send
    f.close
  end

  def test_compressed_send_can_be_disabled
    f = write_config(VALID_CONFIG + "    compressed_send: false\n")
    assert_equal false, ZFSReplicate::Config.load(f.path).replications.first.compressed_send
    f.close
  end

  def test_bwlimit_defaults_nil
    f = write_config(VALID_CONFIG)
    assert_nil ZFSReplicate::Config.load(f.path).replications.first.bwlimit
    f.close
  end

  def test_bwlimit_parsed
    f = write_config(VALID_CONFIG + "    bwlimit: 50m\n")
    assert_equal '50m', ZFSReplicate::Config.load(f.path).replications.first.bwlimit
    f.close
  end

  def test_keep_snapshots_rejects_zero
    # keep_snapshots: 0 would prune every managed snapshot, including the one
    # just sent, leaving no common base for the next run.
    f = write_config(VALID_CONFIG.sub('keep_snapshots: 14', 'keep_snapshots: 0'))
    err = assert_raises(ZFSReplicate::ConfigError) { ZFSReplicate::Config.load(f.path) }
    assert_match(/keep_snapshots/, err.message)
    f.close
  end

  def test_keep_snapshots_rejects_negative
    f = write_config(VALID_CONFIG.sub('keep_snapshots: 14', 'keep_snapshots: -2'))
    assert_raises(ZFSReplicate::ConfigError) { ZFSReplicate::Config.load(f.path) }
    f.close
  end

  def test_keep_snapshots_rejects_non_integer
    f = write_config(VALID_CONFIG.sub('keep_snapshots: 14', 'keep_snapshots: lots'))
    assert_raises(ZFSReplicate::ConfigError) { ZFSReplicate::Config.load(f.path) }
    f.close
  end

  def test_bwlimit_accepts_integer_and_normalizes_to_string
    f = write_config(VALID_CONFIG + "    bwlimit: 50\n")
    assert_equal '50', ZFSReplicate::Config.load(f.path).replications.first.bwlimit
    f.close
  end

  def test_bwlimit_rejects_malformed_values
    ['bwlimit: fast', "bwlimit: '50 m'", 'bwlimit: 50mb', 'bwlimit: -50m',
     'bwlimit: 0', "bwlimit: '0k'"].each do |bad|
      f = write_config(VALID_CONFIG + "    #{bad}\n")
      err = assert_raises(ZFSReplicate::ConfigError, "expected #{bad.inspect} to be rejected") do
        ZFSReplicate::Config.load(f.path)
      end
      assert_match(/bwlimit/, err.message)
      f.close
    end
  end

  def test_rejects_dataset_names_outside_zfs_charset
    ['tank/vms; rm -rf /', 'tank/my vms', "tank/vms\n"].each do |bad|
      f = write_config(VALID_CONFIG.sub('dataset: tank/vms', "dataset: #{bad.inspect}"))
      err = assert_raises(ZFSReplicate::ConfigError, "expected #{bad.inspect} to be rejected") do
        ZFSReplicate::Config.load(f.path)
      end
      assert_match(/dataset/, err.message)
      f.close
    end
  end

  def test_rejects_snapshot_prefix_outside_zfs_charset
    ['my prefix', 'pre;fix', 'pre/fix', 'pre@fix'].each do |bad|
      f = write_config(VALID_CONFIG.sub('snapshot_prefix: zfsreplicate',
                                        "snapshot_prefix: #{bad.inspect}"))
      err = assert_raises(ZFSReplicate::ConfigError, "expected #{bad.inspect} to be rejected") do
        ZFSReplicate::Config.load(f.path)
      end
      assert_match(/snapshot_prefix/, err.message)
      f.close
    end
  end

  # A typo'd key silently applying the default is an unattended-failure mode:
  # `keep_snapshot: 3` would quietly retain 7.
  def test_warns_on_unknown_replication_key
    f = write_config(VALID_CONFIG + "    keep_snapshot: 3\n")
    cfg = ZFSReplicate::Config.load(f.path)
    assert cfg.warnings.any? { |w| w =~ /keep_snapshot/ && w =~ /vms-backup/ },
           "expected a warning naming the key and job, got #{cfg.warnings.inspect}"
    f.close
  end

  def test_warns_on_unknown_top_level_and_endpoint_keys
    yaml = VALID_CONFIG.sub("      user: root\n      dataset: tank/vms",
                            "      user: root\n      prot: 22\n      dataset: tank/vms") +
           "concurency: 2\n"
    assert_includes yaml, 'prot: 22' # guard against the sub silently not matching
    f = write_config(yaml)
    cfg = ZFSReplicate::Config.load(f.path)
    assert cfg.warnings.any? { |w| w =~ /prot/ }, "expected endpoint-key warning, got #{cfg.warnings.inspect}"
    assert cfg.warnings.any? { |w| w =~ /concurency/ }, "expected top-level warning, got #{cfg.warnings.inspect}"
    f.close
  end

  # A permanent force: true silently disarms the overwrite guard on every run;
  # nudge toward the one-shot --force CLI flag.
  def test_warns_on_permanent_force
    f = write_config(VALID_CONFIG + "    force: true\n")
    cfg = ZFSReplicate::Config.load(f.path)
    assert cfg.warnings.any? { |w| w =~ /force/ && w =~ /vms-backup/ },
           "expected a force warning naming the job, got #{cfg.warnings.inspect}"
    f.close
  end

  def test_enabled_defaults_true
    f = write_config(VALID_CONFIG)
    assert_equal true, ZFSReplicate::Config.load(f.path).replications.first.enabled
    f.close
  end

  def test_enabled_can_be_disabled
    f = write_config(VALID_CONFIG + "    enabled: false\n")
    assert_equal false, ZFSReplicate::Config.load(f.path).replications.first.enabled
    f.close
  end

  def test_enabled_rejects_non_boolean
    f = write_config(VALID_CONFIG + "    enabled: maybe\n")
    err = assert_raises(ZFSReplicate::ConfigError) { ZFSReplicate::Config.load(f.path) }
    assert_match(/enabled/, err.message)
    f.close
  end

  def test_no_warnings_for_fully_valid_config
    f = write_config(VALID_CONFIG)
    assert_empty ZFSReplicate::Config.load(f.path).warnings
    f.close
  end

  # Duplicate names share one lock file, so the second job silently reports
  # `skipped` on every run.
  def test_rejects_duplicate_job_names
    dup = VALID_CONFIG + VALID_CONFIG.lines[1..].join
    f = write_config(dup)
    err = assert_raises(ZFSReplicate::ConfigError) { ZFSReplicate::Config.load(f.path) }
    assert_match(/vms-backup/, err.message)
    f.close
  end

  def test_timeout_defaults_nil
    f = write_config(VALID_CONFIG)
    assert_nil ZFSReplicate::Config.load(f.path).replications.first.timeout
    f.close
  end

  def test_timeout_parsed
    f = write_config(VALID_CONFIG + "    timeout: 600\n")
    assert_equal 600, ZFSReplicate::Config.load(f.path).replications.first.timeout
    f.close
  end

  def test_timeout_rejects_zero
    f = write_config(VALID_CONFIG + "    timeout: 0\n")
    assert_raises(ZFSReplicate::ConfigError) { ZFSReplicate::Config.load(f.path) }
    f.close
  end

  def test_timeout_rejects_negative
    f = write_config(VALID_CONFIG + "    timeout: -5\n")
    assert_raises(ZFSReplicate::ConfigError) { ZFSReplicate::Config.load(f.path) }
    f.close
  end

  def test_timeout_rejects_non_integer
    f = write_config(VALID_CONFIG + "    timeout: soon\n")
    assert_raises(ZFSReplicate::ConfigError) { ZFSReplicate::Config.load(f.path) }
    f.close
  end
end
