# test/test_examples.rb
require 'test_helper'
require 'zfsreplicate/config'

# Guards the shipped examples against config-schema drift: every YAML under
# examples/configs/ must load cleanly through Config.load.
class TestExamples < Minitest::Test
  EXAMPLES = Dir[File.expand_path('../../examples/configs/*.yml', __FILE__)].sort

  def test_examples_present
    refute_empty EXAMPLES, 'expected example configs under examples/configs/'
  end

  EXAMPLES.each do |path|
    name = File.basename(path)
    define_method("test_example_#{name.gsub(/\W/, '_')}_loads") do
      cfg = ZFSReplicate::Config.load(path)
      refute_empty cfg.replications, "#{name}: expected at least one replication"
    end
  end
end
