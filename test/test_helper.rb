# test/test_helper.rb
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'minitest/autorun'
require 'zfsreplicate/log'

# Keep test output pristine; tests assert on behavior, not log lines.
ZFSReplicate.log_level = Logger::FATAL
