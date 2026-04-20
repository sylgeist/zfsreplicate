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
end
