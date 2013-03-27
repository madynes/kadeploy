# Kadeploy 3.1
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2011
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

#Kadeploy libs
require 'nodes'

#Ruby libs
require 'thread'

#module ParallelRunner
  #class PRunner
  class ParallelRunner
    @execs = nil
    @output = nil
    @threads = nil
    @runthread = nil


    # Constructor of PRunner
    #
    # Arguments
    # * output: instance of OutputControl
    # Output
    # * nothing
    def initialize(output, nodesetid=-1)
      @execs = {}
      @output = output
      @nodesetid = nodesetid

      @threads = ThreadGroup.new
    end

    # Add a command related to a node
    #
    # Arguments
    # * cmd: string of the command
    # * node: instance of Node
    # Output
    # * nothing
    def add(cmd, node)
      @execs[node] = Execute[cmd]
    end

    # Run the bunch of commands
    #
    # Arguments
    # * nothing
    # Output
    # * nothing
    def run
      @runthread = Thread.new do
        Thread.current[:launched] = false
        @execs.each_value do |exec|
          exec.run
        end
        Thread.current[:launched] = true
        while true do
          if Thread.current[:quit]
            break
          elsif Thread.current[:kill]
            @execs.each_value do |exec|
              exec.kill
            end
            break
          end
          sleep 1
        end
      end
      sleep 1 while !@runthread[:launched]
      @execs.each_pair do |node,exec|
        tid = Thread.new do
          #exec.run
          status,stdout,stderr = exec.wait
          node.last_cmd_stdout = stdout.chomp
          node.last_cmd_stderr = stderr.chomp
          node.last_cmd_exit_status = status.exitstatus.to_s
        end
        @threads.add(tid)
      end
    end

    # Wait the end of all the executions
    #
    # Arguments
    # * nothing
    # Output
    # * nothing
    def wait
      @threads.list.each do |thr|
        thr.join
      end
      @runthread[:quit] = true
      @runthread.join
      @runthread = nil
      @threads = ThreadGroup.new
    end

    # Kill every running process
    def kill
      @threads.list.each do |thr|
        thr.kill! if thr.alive?
        thr.join
      end
=begin
i = 1
      @execs.each_value do |exec|
puts i
i += 1
        exec.kill
      end
=end
      @runthread[:kill] = true
      @runthread.join
      @runthread = nil
    end

    # Get the results of the execution
    #
    # Arguments
    # * nothing
    # Output
    # * array of two arrays ([0] contains the nodes OK and [1] contains the nodes KO)
    def get_results(expects={})
      good = []
      bad = []

      @execs.each_pair do |node,exec|
        status = (expects[:status] ? expects[:status] : ['0'])

        unless status.include?(node.last_cmd_exit_status)
          bad << node
          next
        end

        if expects[:output] and node.last_cmd_stdout.split("\n")[0] != expects[:output]
          bad << node
          next
        end

        good << node

        # to be removed
        nodeset = Nodes::NodeSet.new
        nodeset.id = @nodesetid
        nodeset.push(node)
        @output.debug(exec.command, nodeset)
        nodeset = nil
      end

      [good, bad]
    end
  end
#end
