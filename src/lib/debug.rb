# Kadeploy 3.1
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2011
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

#Ruby libs
require 'syslog'

module Debug
  # Print an error message on a local client
  #
  # Arguments
  # * msg: error message
  # * usage_handler(opt): usage handler
  # Output
  # * nothing
  def Debug::local_client_error(msg, usage_handler = nil)
    puts "ERROR: #{msg}."
    puts "---"
    if (usage_handler == nil) then
      puts "Use the -h or --help option for correct use."
    else
      usage_handler.call
    end
  end

  # Print an error message on a distant client
  #
  # Arguments
  # * msg: error message
  # * client: DRb client handler
  # Output
  # * nothing
  def Debug::distant_client_error(msg, client)
    client.print("ERROR: #{msg}") if client != nil
  end

  # Print a message
  #
  # Arguments
  # * msg: message
  # * client: DRb client handler
  # Output
  # * nothing
  def Debug::distant_client_print(msg, client)
    client.print(msg) if client != nil
  end

  class OutputControl
    @verbose_level = 0
    @debug = nil
    @client = nil
    @user = nil
    @deploy_id = nil
    @syslog = nil
    @syslog_dbg_level = nil
    @syslog_lock = nil
    @client_output = nil
    @cluster_id = nil

    # Constructor of OutputControl
    #
    # Arguments
    # * verbose_level: verbose level at the runtime
    # * debug: boolean user to know if the extra debug must be used or not 
    # * client: Drb handler of the client
    # * user: username
    # * deploy_id: id of the deployment
    # * syslog: boolean used to know if syslog must be used or not
    # * syslog_dbg_level: level of debug required in syslog
    # * syslog_lock: mutex on Syslog
    # Output
    # * nothing
    def initialize(verbose_level, debug, client, user, deploy_id, syslog, syslog_dbg_level, syslog_lock, cluster_id=nil)
      @verbose_level = verbose_level
      @debug = debug
      @client = client
      @user = user
      @deploy_id = deploy_id
      @syslog = syslog
      @syslog_dbg_level = syslog_dbg_level
      @syslog_lock = syslog_lock
      @client_output = (client != nil)
      @cluster_id = cluster_id
    end

    # Disable the output redirection on the client
    #
    # Arguments
    # * nothing
    # Output
    # * nothing
    def disable_client_output
      @client_output = false
    end

    def Debug.prefix(clid,nsid=nil)
      ns = nsid if !nsid.nil? and nsid > 0

      if !clid.nil? and !clid.empty?
        "[#{clid}#{(ns.nil? ? '' : ".#{ns}")}] "
      elsif !ns.nil?
        "[#{ns}] "
      else
        ''
      end
    end

    # Print a message according to a specified debug level
    #
    # Arguments
    # * l: debug level of the message
    # * msg: message
    # * nodeset: print with this NodeSet id
    # Output
    # * prints the message on the server and on the client
    def verbosel(l, msg, nsid=nil, print_prefix = true)
      msg = "#{Debug.prefix(@cluster_id,nsid)}#{msg}" if print_prefix

      if ((l <= @verbose_level) && @client_output)
        begin
          @client.print(msg)
        rescue DRb::DRbConnError
        end
      end
      server_str = "#{@deploy_id}|#{@user} -> #{msg}"
      puts server_str
      if (@syslog && (l <= @syslog_dbg_level)) then
        @syslog_lock.lock
        while Syslog.opened?
          sleep 0.2
        end
        sl = Syslog.open("Kadeploy-dbg")
        sl.log(Syslog::LOG_NOTICE, "#{server_str}")
        sl.close
        @syslog_lock.unlock
      end
    end

    # Print the debug output of a command
    #
    # Arguments
    # * cmd: command
    # * nodeset: NodeSet containing the Nodes on which the command has been launched
    # Output
    # * nothing
    def debug(cmd, nodeset)
      if @debug then
        procprint = Proc.new do |str|
          str = "(#{nodeset.id}) #{str}" if nodeset.id > 0
          @client.print(str)
        end

        procprint.call("-------------------------")
        procprint.call("CMD: #{cmd}")
        if (nodeset != nil) then
          nodeset.set.each { |node|
            node.last_cmd_stdout.split("\n").each { |line|
              procprint.call("#{node.hostname} -- STDOUT: #{line}")
            }
            node.last_cmd_stderr.split("\n").each { |line|
              procprint.call("#{node.hostname} -- STDERR: #{line}")
            }
            node.last_cmd_exit_status.split("\n").each { |line|
              procprint.call("#{node.hostname} -- EXIT STATUS: #{line}")
            }
          }
        end
        procprint.call("-------------------------")
      end
    end

    # Print a message on the server side
    #
    # Arguments
    # * msg: message
    # Output
    # * prints the message on the server and on the client
    def debug_server(msg)
      server_str = "#{@deploy_id}|#{@user} -> #{msg}"
      puts server_str
      if @syslog then
        @syslog_lock.lock
        while Syslog.opened?
          sleep 0.2
        end
        sl = Syslog.open("Kadeploy-dbg")
        sl.log(Syslog::LOG_NOTICE, "#{server_str}")
        sl.close
        @syslog_lock.unlock
      end
    end

    # Print the debug output of a command
    #
    # Arguments
    # * cmd: command
    # * stdout: standard output
    # * stderr: standard error output
    # * exit_status: exit status
    # * nodeset: the nodesed the command was applied on (used for the display template)
    # Output
    # * nothing
    def debug_command(cmd, stdout, stderr, exit_status, nodeset)
      if @debug then
        procprint = Proc.new do |str|
          str = "(#{nodeset.id}) #{str}" if nodeset.id > 0
          @client.print(str)
        end

        procprint.call("-------------------------")
        procprint.call("CMD: #{cmd}")
        if stdout != nil then
          stdout.split("\n").each { |line|
            procprint.call("-- STDOUT: #{line}")
          }
        end
        if stderr != nil then
          stderr.split("\n").each { |line|
            procprint.call("-- STDERR: #{line}")
          }
        end
        procprint.call("-- EXIT STATUS: #{exit_status}")
        procprint.call("-------------------------")
      end
    end
  end

  class Logger
    @nodes = nil
    @config = nil
    @db = nil
    @syslog_lock = nil

    # Constructor of Logger
    #
    # Arguments
    # * node_set: NodeSet that contains the nodes implied in the deployment
    # * config: instance of Config
    # * db: database handler
    # * user: username
    # * deploy_id: deployment id
    # * start: start time
    # * env: environment name
    # * anonymous_env: anonymous environment or not
    # * syslog_lock: mutex on Syslog
    # Output
    # * nothing
    def initialize(node_set, config, db, user, deploy_id, start, env, anonymous_env, syslog_lock)
      @nodes = Hash.new
      node_set.make_array_of_hostname.each { |n|
        @nodes[n] = create_node_infos(user, deploy_id, start, env, anonymous_env)
      }
      @config = config
      @db = db
      @syslog_lock = syslog_lock
    end

    # Create an hashtable that contains all the information to log
    #
    # Arguments
    # * user: username
    # * deploy_id: deployment id
    # * start: start time
    # * env: environment name
    # * anonymous_env: anonymous environment or not
    # Output
    # * returns an Hash instance
    def create_node_infos(user, deploy_id, start, env, anonymous_env)
      node_infos = Hash.new
      node_infos["deploy_id"] = deploy_id
      node_infos["user"] = user
      node_infos["step1"] = String.new
      node_infos["step2"] = String.new
      node_infos["step3"] = String.new
      node_infos["timeout_step1"] = 0
      node_infos["timeout_step2"] = 0
      node_infos["timeout_step3"] = 0
      node_infos["retry_step1"] = -1
      node_infos["retry_step2"] = -1
      node_infos["retry_step3"] = -1
      node_infos["start"] = start
      node_infos["step1_duration"] = 0
      node_infos["step2_duration"] = 0
      node_infos["step3_duration"] = 0
      node_infos["env"] = env
      node_infos["anonymous_env"] = anonymous_env
      node_infos["md5"] = String.new
      node_infos["success"] = false
      node_infos["error"] = String.new
      return node_infos
    end

    # Set a value for some nodes in the Logger
    #
    # Arguments
    # * op: information to set
    # * val: value for the information
    # * node_set(opt): Array of nodes
    # Output
    # * nothing
    def set(op, val, node_set = nil)
      if (node_set != nil)
        node_set.make_array_of_hostname.each { |n|
          @nodes[n][op] = val
        }
      else
        @nodes.each_key { |k|
          @nodes[k][op] = val
        }
      end
    end

    # Set the error value for a set of nodes
    #
    # Arguments
    # * node_set: Array of nodes
    # Output
    # * nothing      
    def error(node_set)
      node_set.make_array_of_hostname.each { |n|
        node_set.get_node_by_host(n).last_cmd_stderr = "#{@config.exec_specific.nodes_state[n][0]["macro-step"]}-#{@config.exec_specific.nodes_state[n][1]["micro-step"]}: #{node_set.get_node_by_host(n).last_cmd_stderr}"
        @nodes[n]["error"] = node_set.get_node_by_host(n).last_cmd_stderr
      }
    end

    # Increment an information for a set of nodes
    #
    # Arguments
    # * op: information to increment
    # * node_set(opt): Array of nodes
    # Output
    # * nothing 
    def increment(op, node_set = nil)
      if (node_set != nil)
        node_set.make_array_of_hostname.each { |n|
          @nodes[n][op] += 1
        }
      else
        @nodes.each_key { |k|
          @nodes[k][op] += 1
        }
      end
    end

    # Generic method to dump the logged information
    #
    # Arguments
    # * nothing
    # Output
    # * nothing     
    def dump
      dump_to_file if (@config.common.log_to_file != "")
      dump_to_syslog if (@config.common.log_to_syslog)
      dump_to_db if (@config.common.log_to_db)
    end

    # Dump the logged information to syslog
    #
    # Arguments
    # * nothing
    # Output
    # * nothing
    def dump_to_syslog
      @syslog_lock.lock
      while Syslog.opened?
        sleep 0.2
      end
      sl = Syslog.open("Kadeploy-log")
      @nodes.each_pair { |hostname, node_infos|
        str = node_infos["deploy_id"].to_s + "," + hostname + "," + node_infos["user"] + ","
        str += node_infos["step1"] + "," + node_infos["step2"] + "," + node_infos["step3"]  + ","
        str += node_infos["timeout_step1"].to_s + "," + node_infos["timeout_step2"].to_s + "," + node_infos["timeout_step3"].to_s + ","
        str += node_infos["retry_step1"].to_s + "," + node_infos["retry_step2"].to_s + "," +  node_infos["retry_step3"].to_s + ","
        str += node_infos["start"].to_i.to_s + ","
        str += node_infos["step1_duration"].to_s + "," + node_infos["step2_duration"].to_s + "," + node_infos["step3_duration"].to_s + ","
        str += node_infos["env"] + "," + node_infos["anonymous_env"].to_s + "," + node_infos["md5"]
        str += node_infos["success"].to_s + "," + node_infos["error"].to_s
        sl.log(Syslog::LOG_NOTICE, "#{str}")
      }
      sl.close
      @syslog_lock.unlock
    end

    # Dump the logged information to the database
    #
    # Arguments
    # * nothing
    # Output
    # * nothing
    def dump_to_db
      @nodes.each_pair { |hostname, node_infos|
        res = @db.run_query(
         "INSERT INTO log ( \
          deploy_id, \
          user, \
          hostname, \
          step1, \
          step2, \
          step3, \
          timeout_step1, \
          timeout_step2, \
          timeout_step3, \
          retry_step1, \
          retry_step2, \
          retry_step3, \
          start, \
          step1_duration, \
          step2_duration, \
          step3_duration, \
          env, \
          anonymous_env, \
          md5, \
          success, \
          error) \
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
          node_infos["deploy_id"],
          node_infos["user"],
          hostname,
          node_infos["step1"],
          node_infos["step2"],
          node_infos["step3"],
          node_infos["timeout_step1"],
          node_infos["timeout_step2"],
          node_infos["timeout_step3"],
          node_infos["retry_step1"],
          node_infos["retry_step2"],
          node_infos["retry_step3"],
          node_infos["start"].to_i,
          node_infos["step1_duration"],
          node_infos["step2_duration"],
          node_infos["step3_duration"],
          node_infos["env"],
          node_infos["anonymous_env"].to_s,
          node_infos["md5"],
          node_infos["success"].to_s,
          node_infos["error"].gsub(/"/, "\\\"")
        )
      }
    end

    # Dump the logged information to a file
    #
    # Arguments
    # * nothing
    # Output
    # * nothing
    def dump_to_file
      begin
        fd = File.new(@config.common.log_to_file, File::CREAT | File::APPEND | File::WRONLY, 0644)
        fd.flock(File::LOCK_EX)
        @nodes.each_pair { |hostname, node_infos|
          str = node_infos["deploy_id"].to_s + "," + hostname + "," + node_infos["user"] + ","
          str += node_infos["step1"] + "," + node_infos["step2"] + "," + node_infos["step3"]  + ","
          str += node_infos["timeout_step1"].to_s + "," + node_infos["timeout_step2"].to_s + "," + node_infos["timeout_step3"].to_s + ","
          str += node_infos["retry_step1"].to_s + "," + node_infos["retry_step2"].to_s + "," +  node_infos["retry_step3"].to_s + ","
          str += node_infos["start"].to_i.to_s + ","
          str += node_infos["step1_duration"].to_s + "," + node_infos["step2_duration"].to_s + "," + node_infos["step3_duration"].to_s + ","
          str += node_infos["env"] + "," + node_infos["anonymous_env"].to_s + "," + node_infos["md5"] + ","
          str += node_infos["success"].to_s + "," + node_infos["error"].to_s
          fd.write("#{Time.now.to_i}: #{str}\n")
        }
        fd.flock(File::LOCK_UN)
        fd.close
      rescue
        puts "Cannot write in the log file #{@config.common.log_to_file}"
      end
    end
  end
end


module Printer
  def debug(level,msg,nodesetid=nil,opts={})
    return unless output()
    output().verbosel(level,msg,nodesetid)
  end

  def log(operation,value=nil,nodeset=nil,opts={})
    return unless logger()
    if opts[:increment]
      logger().increment(operation, nodeset)
    else
      logger().set(operation,value,nodeset)
    end
  end
end
