# test/test_report.rb
require 'test_helper'
require 'zfsreplicate/report'

class TestReport < Minitest::Test
  R = Struct.new(:name, :status, :duration, :error)

  def test_summary_lines_mixed
    results = [
      R.new('vms', :ok, 12.34, nil),
      R.new('beta', :failed, 4.1, 'pipeline failed (status 1): boom'),
      R.new('gamma', :skipped, 0.0, nil),
    ]
    lines = ZFSReplicate::Report.summary_lines(results)
    assert_equal 'Summary:', lines.first
    assert(lines.any? { |l| l.include?('vms') && l.include?('ok') && l.include?('12.3s') })
    assert(lines.any? { |l| l.include?('beta') && l.include?('FAILED') && l.include?('boom') })
    assert(lines.any? { |l| l.include?('gamma') && l.include?('skipped') })
    assert_equal '1 ok, 1 failed, 1 skipped', lines.last
  end

  def test_summary_lines_all_ok
    results = [R.new('a', :ok, 1.0, nil), R.new('b', :ok, 2.0, nil)]
    assert_equal '2 ok, 0 failed, 0 skipped', ZFSReplicate::Report.summary_lines(results).last
  end
end
