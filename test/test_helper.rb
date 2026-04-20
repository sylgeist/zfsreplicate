# test/test_helper.rb
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'minitest/autorun'
require 'zfsreplicate/log'

# Simple Mock implementation compatible with Minitest::Mock API
module Minitest
  class Mock
    def initialize
      @expectations = []
      @calls = []
    end

    def expect(method, return_value, args_constraint = [])
      @expectations << {method: method.to_sym, return: return_value, args: args_constraint}
      self
    end

    def method_missing(method, *args, &block)
      @calls << {method: method.to_sym, args: args}

      expected = @expectations.find { |e| e[:method] == method.to_sym }
      if expected
        # Check if arguments match the constraint
        if expected[:args].any?
          # Simple constraint matching: [String] means any String argument
          unless args.length == expected[:args].length
            raise "Wrong number of arguments (given #{args.length}, expected #{expected[:args].length})"
          end

          args.each_with_index do |arg, i|
            constraint = expected[:args][i]
            if constraint.is_a?(Class) && !arg.is_a?(constraint)
              raise "Argument #{i} must be #{constraint}, got #{arg.class}"
            end
          end
        end

        @expectations.delete(expected)
        return expected[:return]
      end

      raise NoMethodError, "Mock received unexpected call: #{method}(#{args.inspect})"
    end

    def verify
      if @expectations.any?
        raise "Mock expectations not met: #{@expectations.inspect}"
      end
    end
  end
end
