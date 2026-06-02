# test/test_log.rb
require 'test_helper'
require 'zfsreplicate/log'

class TestLog < Minitest::Test
  def test_formatter_without_job_tag
    out = ZFSReplicate.logger.formatter.call('INFO', Time.now, 'zfsreplicate', 'hello')
    assert_equal "[INFO] zfsreplicate: hello\n", out
  end

  def test_formatter_with_job_tag
    Thread.current[:zfsreplicate_job] = 'vms'
    out = ZFSReplicate.logger.formatter.call('INFO', Time.now, 'zfsreplicate', 'hello')
    assert_equal "[INFO] zfsreplicate[vms]: hello\n", out
  ensure
    Thread.current[:zfsreplicate_job] = nil
  end
end
