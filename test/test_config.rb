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
end
