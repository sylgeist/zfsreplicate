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
end
