# Kadeploy 3.1
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2010
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

#Contrib libs
require 'taktuk_wrapper'

#Ruby libs
require 'yaml'
require 'socket'
require 'ping'

module ParallelOperations
  class ParallelOps
    @nodes = nil
    @taktuk_connector = nil
    @taktuk_tree_arity = nil
    @taktuk_auto_propagate = nil
    @output = nil
    @config = nil
    @cluster = nil
    @instance_thread = nil
    @process_container = nil

    # Constructor of ParallelOps
    #
    # Arguments   
    # * nodes: instance of NodeSet
    # * config: instance of Config
    # * cluster: cluster
    # * taktuk_connector: specifies the connector to use with Taktuk
    # * output: OutputControl instance
    # * instance_thread: current thread instance
    # * process_container: process container
    # Output
    # * nothing
    def initialize(nodes, config, cluster, taktuk_connector, output, instance_thread, process_container)
      @nodes = nodes
      @config = config
      @cluster = cluster
      @taktuk_connector = taktuk_connector
      @taktuk_tree_arity = config.common.taktuk_tree_arity
      @taktuk_auto_propagate = config.common.taktuk_auto_propagate
      @output = output
      @instance_thread = instance_thread
      @process_container = process_container
    end

    def make_node_list_for_taktuk
      n = String.new
      if @config.cluster_specific[@cluster].use_ip_to_deploy then
        @nodes.make_sorted_array_of_nodes.each { |node|
          n += " -m #{node.ip}"
        }
      else
        @nodes.make_sorted_array_of_nodes.each { |node|
          n += " -m #{node.hostname}"
        }
      end
      return n
    end

    # Generate the header of a Taktuk command
    #
    # Arguments
    # * nothing
    # Output
    # * return a string containing the header of Taktuk command
    def make_taktuk_header_cmd
      args_tab = Array.new
      args_tab.push("-s") if @taktuk_auto_propagate
      if @taktuk_connector != "" then
        args_tab.push("-c")
        args_tab.push("#{@taktuk_connector}")
      end
      return args_tab
    end
    
    # Create a Taktuk string for an exec command
    #
    # Arguments
    # * cmd: command to execute
    # Output
    # * returns a string that contains the Taktuk command line for an exec command
    def make_taktuk_exec_cmd(cmd)
      args = String.new
      args += make_node_list_for_taktuk()
      args += " broadcast exec [ #{cmd} ]"
      return make_taktuk_header_cmd + args.split(" ")
    end

    # Create a Taktuk string for a send file command
    #
    # Arguments
    # * file: file to send
    # * dest_dir: destination dir
    # * scattering_kind: kind of taktuk scatter (tree, chain)
    # Output
    # * returns a string that contains the Taktuk command line for a send file command
    def make_taktuk_send_file_cmd(file, dest_dir, scattering_kind)
      args = String.new
      case scattering_kind
      when "chain"
        args += " -d 1"
      when "tree"
        if (@taktuk_tree_arity > 0) then
          args += " -d #{@taktuk_tree_arity}"
        end
      else
        raise "Invalid structure for broadcasting file"
      end
      args += make_node_list_for_taktuk()
      args += " broadcast put [ #{file} ] [ #{dest_dir} ]"
      return make_taktuk_header_cmd + args.split(" ")
    end

    # Create a Taktuk string for an exec command with an input file
    #
    # Arguments
    # * file: file to send as an input
    # * cmd: command to execute
    # * scattering_kind: kind of taktuk scatter (tree, chain)
    # Output
    # * returns a string that contains the Taktuk command line for an exec command with an input file
    def make_taktuk_exec_cmd_with_input_file(file, cmd, scattering_kind)
      args = String.new
      case scattering_kind
      when "chain"
        args += " -d 1"
      when "tree"
        if (@taktuk_tree_arity > 0) then
          args += " -d #{@taktuk_tree_arity}"
        end
      else
        raise "Invalid structure for broadcasting file"
      end
      args += make_node_list_for_taktuk()
      args += " broadcast exec [ #{cmd} ];"
      args += " broadcast input file [ #{file} ]"
      return make_taktuk_header_cmd + args.split(" ")      
    end
 
    # Init a the state of a NodeSet before a send file command
    #
    # Arguments
    # * nothing
    # Output
    # * nothing
    def init_nodes_state_before_send_file_command
      @nodes.set.each { |node|
        node.last_cmd_exit_status = "0"
        node.last_cmd_stderr = ""
      }
    end

    # Init a the state of a NodeSet before an exec command
    #
    # Arguments
    # * nothing
    # Output
    # * nothing
    def init_nodes_state_before_exec_command
      @nodes.set.each { |node|
        node.last_cmd_exit_status = "256"
        node.last_cmd_stderr = "Unreachable"
      }
    end

    # Init a the state of a NodeSet before a reboot command
    #
    # Arguments
    # * macro_step: name if the current macro step
    # Output
    # * nothing
    def init_nodes_state_before_wait_nodes_after_reboot_command
      @nodes.set.each { |node|
        node.last_cmd_stderr = "Unreachable after the reboot"
        node.state = "KO"
      }
    end

    # Get the return information about an exec command with Taktuk
    #
    # Arguments
    # * tw: instance of TaktukWrapper
    # Output
    # * nothing
    def get_taktuk_exec_command_infos(tw)
      tree = YAML.load((YAML.dump({"hosts"=>tw.hosts,
                                    "connectors"=>tw.connectors,
                                    "errors"=>tw.errors,
                                    "infos"=>tw.infos})))
      init_nodes_state_before_exec_command
      tree['hosts'].each_value { |h|
        h['commands'].each_value { |x|
          if @config.cluster_specific[@cluster].use_ip_to_deploy then
            node = @nodes.get_node_by_ip(h['host_name'])
          else
            node = @nodes.get_node_by_host(h['host_name'])
          end
          node.last_cmd_exit_status = x['status']
          node.last_cmd_stdout = x['output'].chomp.gsub(/\n/,"\\n")
          node.last_cmd_stderr = x['error'].chomp.gsub(/\n/,"\\n")
        }
      }
    end

    # Get the return information about a send file command with Taktuk
    #
    # Arguments
    # * tw: instance of TaktukWrapper
    # Output
    # * nothing
    def get_taktuk_send_file_command_infos(tw)
      tree = YAML.load((YAML.dump({"hosts"=>tw.hosts,
                                    "connectors"=>tw.connectors,
                                    "errors"=>tw.errors,
                                    "infos"=>tw.infos})))
      init_nodes_state_before_send_file_command
      tree['connectors'].each_value { |h|
        if @config.cluster_specific[@cluster].use_ip_to_deploy then
          node = @nodes.get_node_by_ip(h['host_name'])
        else
          node = @nodes.get_node_by_host(h['host_name'])
        end
        node.last_cmd_exit_status = "256"
        node.last_cmd_stderr = "The node #{h['peer']} is unreachable"
       }
    end

    # Get the return information about an exec command with an input file with Taktuk
    #
    # Arguments
    # * tw: instance of TaktukWrapper
    # Output
    # * nothing
    def get_taktuk_exec_cmd_with_input_file_infos(tw)
      tree = YAML.load((YAML.dump({"hosts"=>tw.hosts,
                                    "connectors"=>tw.connectors,
                                    "errors"=>tw.errors,
                                    "infos"=>tw.infos})))
      init_nodes_state_before_exec_command
      tree['hosts'].each_value { |h|
        h['commands'].each_value { |x|
          if @config.cluster_specific[@cluster].use_ip_to_deploy then
            node = @nodes.get_node_by_ip(h['host_name'])
          else
            node = @nodes.get_node_by_host(h['host_name'])
          end
          node.last_cmd_exit_status = x['status']
          node.last_cmd_stdout = x['output'].chomp.gsub(/\n/,"\\n")
          node.last_cmd_stderr = x['error'].chomp.gsub(/\n/,"\\n")
        }
      }
    end

    # Execute a command in parallel
    #
    # Arguments
    # * cmd: command to execute
    # Output
    # * returns an array that contains two arrays ([0] is the nodes OK and [1] is the nodes KO)
    def execute(cmd)
      command_array = make_taktuk_exec_cmd(cmd)
      tw = TaktukWrapper::new(command_array)
      tw.run
      @process_container.add_process(@instance_thread, tw.pid)
      tw.wait
      @process_container.remove_process(@instance_thread, tw.pid)
      get_taktuk_exec_command_infos(tw)
      good_nodes = Array.new
      bad_nodes = Array.new

      @nodes.set.each { |node|
        if node.last_cmd_exit_status == "0" then
          good_nodes.push(node)
        else
          bad_nodes.push(node)
        end
      }
      @output.debug("taktuk #{command_array.join(" ")}", @nodes)
      return [good_nodes, bad_nodes]
    end

    # Execute a command in parallel and expects some exit status
    #
    # Arguments
    # * cmd: command to execute
    # * status: array of expected exit status
    # Output
    # * returns an array that contains two arrays ([0] is the nodes OK and [1] is the nodes KO)
    def execute_expecting_status(cmd, status)
      command_array = make_taktuk_exec_cmd(cmd)
      tw = TaktukWrapper::new(command_array)
      tw.run
      @process_container.add_process(@instance_thread, tw.pid)
      tw.wait
      @process_container.remove_process(@instance_thread, tw.pid)
      get_taktuk_exec_command_infos(tw)
      good_nodes = Array.new
      bad_nodes = Array.new

      @nodes.set.each { |node|
        if status.include?(node.last_cmd_exit_status) then
          good_nodes.push(node)
        else
          bad_nodes.push(node)
        end
      }
      @output.debug("taktuk #{command_array.join(" ")}", @nodes)
      return [good_nodes, bad_nodes]
    end

    # Execute a command in parallel and expects some exit status and an output
    #
    # Arguments
    # * cmd: command to execute
    # * status: array of expected exit status
    # * output: string that contains the expected output (only the first line is checked)
    # Output
    # * returns an array that contains two arrays ([0] is the nodes OK and [1] is the nodes KO)
    def execute_expecting_status_and_output(cmd, status, output)
      command_array = make_taktuk_exec_cmd(cmd)
      tw = TaktukWrapper::new(command_array)
      tw.run
      @process_container.add_process(@instance_thread, tw.pid)
      tw.wait
      @process_container.remove_process(@instance_thread, tw.pid)
      get_taktuk_exec_command_infos(tw)
      good_nodes = Array.new
      bad_nodes = Array.new

      @nodes.set.each { |node|
        if (status.include?(node.last_cmd_exit_status) == true) && 
            (node.last_cmd_stdout.split("\n")[0] == output) then
          good_nodes.push(node)
        else
          bad_nodes.push(node)
        end
      }
      @output.debug("taktuk #{command_array.join(" ")}", @nodes)
      return [good_nodes, bad_nodes]
    end

    # Send a file in parallel
    #
    # Arguments
    # * file: file to send
    # * dest_dir: destination dir
    # * scattering_kind: kind of taktuk scatter (tree, chain)
    # Output
    # * returns an array that contains two arrays ([0] is the nodes OK and [1] is the nodes KO)    
    def send_file(file, dest_dir, scattering_kind)
      command_array = make_taktuk_send_file_cmd(file, dest_dir, scattering_kind)
      tw = TaktukWrapper::new(command_array)
      tw.run
      @process_container.add_process(@instance_thread, tw.pid)
      tw.wait
      @process_container.remove_process(@instance_thread, tw.pid)
      get_taktuk_send_file_command_infos(tw)
      good_nodes = Array.new
      bad_nodes = Array.new
      @nodes.set.each { |node|
        if node.last_cmd_exit_status == "0" then
          good_nodes.push(node)
        else
          bad_nodes.push(node)
        end
      }
      @output.debug("taktuk #{command_array.join(" ")}", @nodes)
      return [good_nodes, bad_nodes]   
    end

    # Execute a command in parallel with an input file
    #
    # Arguments
    # * file: file to send
    # * cmd: command to execute
    # * scattering_kind: kind of taktuk scatter (tree, chain)
    # * status: array of expected exit status
    # Output
    # * returns an array that contains two arrays ([0] is the nodes OK and [1] is the nodes KO)    
    def exec_cmd_with_input_file(file, cmd, scattering_kind, status)
      command_array = make_taktuk_exec_cmd_with_input_file(file, cmd, scattering_kind)
      tw = TaktukWrapper::new(command_array)
      tw.run
      @process_container.add_process(@instance_thread, tw.pid)
      tw.wait
      @process_container.remove_process(@instance_thread, tw.pid)
      get_taktuk_exec_cmd_with_input_file_infos(tw)
      good_nodes = Array.new
      bad_nodes = Array.new
      @nodes.set.each { |node|
        if node.last_cmd_exit_status == status then
          good_nodes.push(node)
        else
          bad_nodes.push(node)
        end
      }
      @output.debug("taktuk #{command_array.join(" ")}", @nodes)
      return [good_nodes, bad_nodes]
    end

    # Wait for several nodes after a reboot command and wait a give time the effective reboot
    #
    # Arguments
    # * timeout: time to wait
    # * ports_up: array of ports that must be up on the rebooted nodes to test
    # * ports_down: array of ports that must be down on the rebooted nodes to test
    # * nodes_check_window: instance of WindowManager
    # * last_reboot: specify if we wait the last reboot
    # Output
    # * returns an array that contains two arrays ([0] is the nodes OK and [1] is the nodes KO)    
    def wait_nodes_after_reboot(timeout, ports_up, ports_down, nodes_check_window, last_reboot)
      start = Time.now.tv_sec
      good_nodes = Array.new
      bad_nodes = Array.new
      init_nodes_state_before_wait_nodes_after_reboot_command
      @nodes.set.each { |node|
        @config.set_node_state(node.hostname, "", "", "reboot_in_progress")
      }
      sleep(20)
      
      n = @nodes.length
      t = eval(timeout).to_i

      while (((Time.now.tv_sec - start) < t) && (not @nodes.all_ok?))
        sleep(5)
        nodes_to_test = Nodes::NodeSet.new
        @nodes.set.each { |node|
          if node.state == "KO" then
            nodes_to_test.push(node)
          end
        }
        callback = Proc.new { |ns|
          tg = ThreadGroup.new
          ns.set.each { |node|
            sub_tid = Thread.new {
              all_ports_ok = true
              
              if (last_reboot && (@config.exec_specific.vlan != nil)) then
                nodeid = @config.exec_specific.ip_in_vlan[node.hostname]
              else
                if (@config.cluster_specific[@cluster].use_ip_to_deploy) then
                  nodeid = node.ip
                else
                  nodeid = node.hostname
                end
              end
              if Ping.pingecho(nodeid, 1, @config.common.ssh_port) then
                ports_up.each { |port|
                  begin
                    s = TCPsocket.open(nodeid, port)
                    s.close
                  rescue Errno::ECONNREFUSED
                    all_ports_ok = false
                    next
                  rescue Errno::EHOSTUNREACH
                    all_ports_ok = false
                    next
                  end
                }
                if all_ports_ok then
                  ports_down.each { |port|
                    begin
                      s = TCPsocket.open(nodeid, port)
                      all_ports_ok = false
                      s.close
                    rescue Errno::ECONNREFUSED
                      next
                    rescue Errno::EHOSTUNREACH
                      all_ports_ok = false
                      next
                    end
                  }
                end
                if all_ports_ok then
                  node.state = "OK"
                  node.last_cmd_exit_status = "0"
                  node.last_cmd_stderr = ""
                  @output.verbosel(4, "  *** #{node.hostname} is here after #{Time.now.tv_sec - start}s")
                  @config.set_node_state(node.hostname, "", "", "rebooted")
                else
                  node.state = "KO"
                end
              end
            }
            tg.add(sub_tid)
          }
          #let's wait everybody
          tg.list.each { |sub_tid|
            sub_tid.join
          }
        }
        nodes_check_window.launch_on_node_set(nodes_to_test, &callback)
        nodes_to_test = nil
      end

      @nodes.set.each { |node|
        if node.state == "OK" then
          good_nodes.push(node)
        else
          bad_nodes.push(node)
        end
      }
      return [good_nodes, bad_nodes]
    end
  end
end
