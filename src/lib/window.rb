# Kadeploy 3.1
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2012
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

#Kadeploy libs
require 'debug'
require 'nodes'
require 'error'

#Ruby libs
require 'thread'
require 'uri'
require 'tempfile'

module Managers
  class WindowManager
    @mutex = nil
    @resources_used = nil
    @resources_max = nil
    @sleep_time = nil

    # Constructor of WindowManager
    #
    # Arguments
    # * max: max size of the window
    # * sleep_time: sleeping time before releasing resources
    # Output
    # * nothing
    def initialize(max, sleep_time)
      @mutex = Mutex.new
      @resources_used = 0
      @resources_max = max
      @sleep_time = sleep_time
      @last_release_time = 0
    end

    private
    # Try to acquire a given number of resources
    #
    # Arguments
    # * n: number of resources to acquire
    # Output
    # * returns two values: the number of resources not acquires and the number of taken resources
    def acquire(n)
      @mutex.synchronize {
        remaining_resources = @resources_max - @resources_used
        if (remaining_resources == 0) then
          return n, 0
        else
          if (n <= remaining_resources) then
            @resources_used += n
            return 0, n
          else
            not_acquired = n - remaining_resources
            @resources_used = @resources_max
            return not_acquired, remaining_resources
          end
        end
      }
    end
    
    # Release a given number of resources
    #
    # Arguments
    # * n: number of resources to release
    # Output
    # * nothing
    def release(n)
      @mutex.synchronize {
        @resources_used -= n
        @resources_used = 0 if @resources_used < 0
        @last_release_time = Time.now.to_i
      }
    end
    
    def regenerate_lost_resources
      @mutex.synchronize {
        if ((Time.now.to_i - @last_release_time) > (2 * @sleep_time)) && (@resources_used != 0) then
          @resources_used = 0
        end
      }
    end

    public
    # Launch a windowed function
    #
    # Arguments
    # * node_set: instance of NodeSet
    # * callback: reference on block that takes a NodeSet as argument
    # Output
    # * nothing
    def launch_on_node_set(node_set, &callback)
      remaining = node_set.length
      while (remaining != 0)
        regenerate_lost_resources()
        remaining, taken = acquire(remaining)
        if (taken > 0) then
          partial_set = node_set.extract(taken)
          callback.call(partial_set)
          release(taken)
        end
        sleep(@sleep_time) if remaining != 0
      end
    end

    def launch_on_node_array(node_array, &callback)
      remaining = node_array.length
      while (remaining != 0)
        regenerate_lost_resources()
        remaining, taken = acquire(remaining)
        if (taken > 0) then
          partial_array = Array.new
          (1..taken).each { partial_array.push(node_array.shift) }
          callback.call(partial_array)
          release(taken)
        end
        sleep(@sleep_time) if remaining != 0
      end
    end
  end
end
