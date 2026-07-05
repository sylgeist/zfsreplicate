# frozen_string_literal: true
require 'test_helper'
require 'stringio'
require 'logger'

class TestLogTag < Minitest::Test
  # Build a logger with the same formatter as production but writing to a buffer.
  def capture_logger
    buf = StringIO.new
    l = Logger.new(buf)
    l.progname = 'zfsreplicate'
    l.formatter = ZFSReplicate.log_formatter
    [l, buf]
  end

  def test_untagged_format_unchanged
    l, buf = capture_logger
    Thread.current[:zfsreplicate_job] = nil
    l.info('hello')
    assert_match(/\[INFO\] zfsreplicate: hello/, buf.string)
  end

  def test_tagged_format_includes_job
    l, buf = capture_logger
    Thread.current[:zfsreplicate_job] = 'vms-backup'
    l.info('hello')
    assert_match(/\[INFO\] zfsreplicate\(vms-backup\): hello/, buf.string)
  ensure
    Thread.current[:zfsreplicate_job] = nil
  end
end
