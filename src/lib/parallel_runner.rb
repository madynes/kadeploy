# Kadeploy 3.1
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2010
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

#Kadeploy libs
require 'nodes'

#Ruby libs
require 'thread'

module ParallelRunner
  class Command
    attr_reader :cmd
    attr_reader :stdout
    attr_reader :stderr
    attr_reader :pid
    attr_reader :status

    # Constructor of Command
    #
    # Arguments
    # * cmd: string of the command
    # Output
    # * nothing
    def initialize(cmd)
      @cmd = cmd
      @status = nil
    end

    # Run the command
    #
    # Arguments
    # * nothing
    # Output
    # * nothing
    def run
      @stdout, @mystdout = IO::pipe
      @stderr, @mystderr = IO::pipe
      @pid = fork {
        @stdout.close
        @stderr.close
        @mystdout.sync = true
        @mystderr.sync = true
        STDOUT.reopen(@mystdout)
        STDERR.reopen(@mystderr)
        begin
          exec(@cmd)
        rescue
          exit!(1)
        end
      }
      @mystdout.close
      @mystderr.close
    end

    # Wait the end of the command
    #
    # Arguments
    # * nothing
    # Output
    # * nothing    
    def wait
      if not @status
        Process::waitpid(@pid)
        @status = $?
      end
    end
  end

  class PRunner
    @nodes = nil
    @output = nil
    @instance_thread = nil
    @process_container = nil

    # Constructor of PRunner
    #
    # Arguments
    # * output: instance of OutputControl
    # Output
    # * nothing
    def initialize(output, instance_thread, process_container)
      @nodes = Hash.new
      @output = output
      @instance_thread = instance_thread
      @process_container = process_container
    end

    # Add a command related to a node
    #
    # Arguments
    # * cmd: string of the command
    # * node: instance of Node
    # Output
    # * nothing
    def add(cmd, node)
      @nodes[node] = Hash.new
      @nodes[node]["cmd"] = Command.new(cmd)
      @nodes[node]["stdout_fd"] = nil
      @nodes[node]["stdout_reader"] = nil
      @nodes[node]["stderr_reader"] = nil
    end

    # Run the bunch of commands
    #
    # Arguments
    # * nothing
    # Output
    # * nothing   
    def run
      @nodes.each_key { |node|
        @nodes[node]["cmd"].run
        @process_container.add_process(@instance_thread, @nodes[node]["cmd"].pid) if @instance_thread != nil
        @nodes[node]["stdout_fd"] = @nodes[node]["cmd"].stdout
        @nodes[node]["stderr_fd"] = @nodes[node]["cmd"].stderr
        @nodes[node]["stdout_reader"] = Thread.new { 
          begin
            node.last_cmd_stdout = ""
            while line = @nodes[node]["stdout_fd"].gets
              node.last_cmd_stdout += line
            end
          ensure
            @nodes[node]["stdout_fd"].close
          end
        }
        @nodes[node]["stderr_reader"] = Thread.new { 
          begin
            node.last_cmd_stderr = ""
            while line = @nodes[node]["stderr_fd"].gets
              node.last_cmd_stderr += line
            end
          ensure
            @nodes[node]["stderr_fd"].close
          end
        }
      }
    end

    # Wait the end of all the executions
    #
    # Arguments
    # * nothing
    # Output
    # * nothing
    def wait
      @nodes.each_key { |node|
        @nodes[node]["cmd"].wait
        @process_container.remove_process(@instance_thread, @nodes[node]["cmd"].pid) if @instance_thread != nil
        node.last_cmd_exit_status = @nodes[node]["cmd"].status.to_s
        @nodes[node]["stdout_reader"].join
        @nodes[node]["stderr_reader"].join
      }
    end

    # Get the results of the execution
    #
    # Arguments
    # * nothing
    # Output
    # * array of two arrays ([0] contains the nodes OK and [1] contains the nodes KO)   
    def get_results
      good_nodes = Array.new
      bad_nodes = Array.new
      @nodes.each_key { |node|
        node.last_cmd_stdout = node.last_cmd_stdout.chomp.gsub(/\n/,"\\n")
        node.last_cmd_stderr = node.last_cmd_stderr.chomp.gsub(/\n/,"\\n")
        if (node.last_cmd_exit_status == "0") then
#          good_nodes.push(node.dup)
          good_nodes.push(node)
        else
#          bad_nodes.push(node.dup)
          bad_nodes.push(node)
        end
        nodeset = Nodes::NodeSet.new
        nodeset.push(node)
        @output.debug(@nodes[node]["cmd"].cmd, nodeset)
        nodeset = nil
      }
      return [good_nodes, bad_nodes]
    end

    # Get the results of the execution and expect an output
    #
    # Arguments
    # * value: expected value
    # * error_msg: error message
    # Output
    # * array of two arrays ([0] contains the nodes OK and [1] contains the nodes KO)   
    def get_results_expecting_output(value, error_msg)
      good_nodes = Array.new
      bad_nodes = Array.new
      @nodes.each_key { |node|
        if (node.last_cmd_exit_status == "0") then
          if (node.last_cmd_stdout.split("\n")[0] == value) then
#            good_nodes.push(node.dup)
            good_nodes.push(node)
          else
            node.last_cmd_stderr = error_msg
#            bad_nodes.push(node.dup)
            bad_nodes.push(node)
          end
        else
          node.last_cmd_stderr = "Cannot connect to the node"
          bad_nodes.push(node)
        end
        nodeset = Nodes::NodeSet.new
        nodeset.push(node)
        @output.debug(@nodes[node]["cmd"].cmd, nodeset)
        nodeset = nil
      }
      return [good_nodes, bad_nodes]
    end
  end
end
