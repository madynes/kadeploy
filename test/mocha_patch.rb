require 'test/unit'
require 'mocha'

module Mocha
  class Expectation
    def lasts(*values)
      @return_values.durations += values
      self
    end
  end

  class ReturnValues
    alias_method :__initialize__, :initialize
    alias_method :'__+__', :+
    attr_reader :durations

    def initialize(*values)
      __initialize__(*values)
      @durations = []
    end

    def durations=(val)
      @durations=val
      self
    end

    def +(other)
      send(:'__+__',other).send(:durations=,@durations)
    end

    def next
      case @values.length
        when 0 then
          (@durations.length > 1 ? @durations.shift : @durations.first)
          nil
        when 1 then @values.first.evaluate(
          (@durations.length > 1 ? @durations.shift : @durations.first)
        )
        else @values.shift.evaluate(
          (@durations.length > 1 ? @durations.shift : @durations.first)
        )
      end
    end
  end

  class SingleReturnValue
    def evaluate(duration)
      sleep(duration) if duration and duration.is_a?(Fixnum)
      @value
    end
  end
end
