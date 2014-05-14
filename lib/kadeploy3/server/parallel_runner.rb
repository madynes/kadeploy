require 'thread'

module Kadeploy
  class ParallelRunner
    @execs = nil
    @output = nil
    @threads = nil


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

    def free
      if @execs
        @execs.each_value{|ex| ex.free}
        @execs.clear
      end
      @execs = nil
      @output = nil
      @nodesetid = nil
      @threads = nil
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
      @execs.each_pair do |node,exec|
        tid = Thread.new do
          exec.run
          status,stdout,stderr = exec.wait(:checkstatus => false)
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
      @runthread = Thread.current
      @threads.list.each do |thr|
        thr.join
      end
      @threads = ThreadGroup.new
    end

    # Kill every running process
    def kill
      @execs.each_value do |exec|
        exec.kill
      end

      # Waiting threads from @threads that will die by themselves
      @threads.list.each do |thr|
        begin
          thr.join
        rescue SignalException
        end
      end

      free()
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

        if !status.include?(node.last_cmd_exit_status)
          bad << node
        elsif expects[:output] and node.last_cmd_stdout.split("\n")[0] != expects[:output]
          bad << node
        else
          good << node
        end

        # to be removed
        nodeset = Nodes::NodeSet.new
        nodeset.id = @nodesetid
        nodeset.push(node)
        @output.push(exec.command, nodeset) if @output
        nodeset = nil
      end

      [good, bad]
    end
  end
end
