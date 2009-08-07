#!/usr/bin/ruby -w

# Kadeploy 3.0
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008, 2009
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

#Kadeploy libs
require 'managers'
require 'debug'
require 'microsteps'
require 'process_management'

#Ruby libs
require 'drb'
require 'socket'
require 'yaml'

class KadeployServer
  @config = nil
  @client = nil
  attr_reader :deployments_table_lock
  attr_reader :tcp_buffer_size
  attr_reader :dest_host
  attr_reader :dest_port
  @db = nil
  @reboot_window = nil
  @nodes_check_window = nil
  @syslog_lock = nil
  @workflow_hash = nil
  @workflow_hash_lock = nil
  @workflow_hash_index = nil
  
  # Constructor of KadeployServer
  #
  # Arguments
  # * config: instance of Config
  # * reboot_window: instance of WindowManager to manage the reboot window
  # * nodes_check_window: instance of WindowManager to manage the check of the nodes
  # * db: database handler
  # Output
  # * raises an exception if the file server can not open a socket
  def initialize(config, reboot_window, nodes_check_window, db)
    @config = config
    @dest_host = @config.common.kadeploy_server
    @tcp_buffer_size = @config.common.kadeploy_tcp_buffer_size
    @reboot_window = reboot_window
    @nodes_check_window = nodes_check_window
    puts "Launching the Kadeploy file server"
    @deployments_table_lock = Mutex.new
    @syslog_lock = Mutex.new
    @db = db
    @workflow_info_hash = Hash.new
    @workflow_info_hash_lock = Mutex.new
    @workflow_info_hash_index = 0
  end

  # Record a Managers::WorkflowManager pointer
  #
  # Arguments
  # * workflow_ptr: reference toward a Managers::WorkflowManager
  # Output
  # * return an id that allows to find the right Managers::WorkflowManager reference
  def add_workflow_info(workflow_ptr)
    @workflow_info_hash_lock.lock
    id = @workflow_info_hash_index
    @workflow_info_hash[id] = workflow_ptr
    @workflow_info_hash_index += 1
    @workflow_info_hash_lock.unlock
    return id
  end

  # Delete the information of a workflow
  #
  # Arguments
  # * id: workflow id
  # Output
  # * nothing
  def delete_workflow_info(id)
    @workflow_info_hash_lock.lock
    @workflow_info_hash.delete(id)
    @workflow_info_hash_lock.unlock
  end

  # Get a YAML output of the workflows (RPC)
  #
  # Arguments
  # * wid: workflow id
  # Output
  # * return a string containing the YAML output
  def get_workflow_state(wid = "")
    str = String.new
    id = wid.to_i if (wid != "")
    @workflow_info_hash_lock.lock
    if (@workflow_info_hash.has_key?(id)) then
      hash = Hash.new
      hash[id] = @workflow_info_hash[id].get_state
      str = hash.to_yaml
      hash = nil
    elsif (wid == "") then
      hash = Hash.new
      @workflow_info_hash.each_pair { |key,workflow_info_hash|
        hash[key] = workflow_info_hash.get_state
      }
      str = hash.to_yaml
      hash = nil
    end
    @workflow_info_hash_lock.unlock
    return str
  end
  
  # Create a socket server designed to copy a file from to client to the server cache (RPC)
  #
  # Arguments
  # * filename: name of the destination file
  # Output
  # * return the port allocated to the socket server
  def create_a_socket_server(filename)
    sock = Socket.new(Socket::AF_INET, Socket::SOCK_STREAM, 0)
    sockaddr = Socket.pack_sockaddr_in(0, @config.common.kadeploy_server)
    begin
      sock.bind(sockaddr)
    rescue
      return -1
    end
    port = Socket.unpack_sockaddr_in(sock.getsockname)[0].to_i
    Thread.new {
      sock.listen(10)
      begin
        session = sock.accept
        file = File.new(@config.common.kadeploy_cache_dir + "/" + filename, "w")
        while ((buf = session[0].recv(@tcp_buffer_size)) != "") do
          file.write(buf)
        end
        file.close
        session[0].close
      rescue
        puts "The client has been probably disconnected..."
      end
    }
    return port
  end

  # Kill a workflow (RPC)
  #
  # Arguments
  # * id: id of the workflow
  # Output
  # * nothing  
  def kill(id)
    # id == -1 means that the workflow has not been launched yet
    if (id != -1) then
      workflow = @workflow_info_hash[id]
      workflow.kill()
      delete_workflow_info(id)
    end
  end

  # Get the common configuration (RPC)
  #
  # Arguments
  # * nothing
  # Output
  # * return a CommonConfig instance
  def get_common_config
    return @config.common
  end

  # Get the default deployment partition (RPC)
  #
  # Arguments
  # * cluster: name of the cluster concerned
  # Output
  # * return the name of the default deployment partition
  def get_default_deploy_part(cluster)
    return @config.cluster_specific[cluster].block_device + @config.cluster_specific[cluster].deploy_part
  end

  # Get the block device (RPC)
  #
  # Arguments
  # * cluster: name of the cluster concerned
  # Output
  # * return the name of the block device
  def get_block_device(cluster)
    return @config.cluster_specific[cluster].block_device
  end

  # Get the production partition (RPC)
  #
  # Arguments
  # * cluster: name of the cluster concerned
  # Output
  # * return the production partition
  def get_prod_part(cluster)
    return @config.cluster_specific[cluster].block_device + @config.cluster_specific[cluster].prod_part
  end


  # Launch the workflow from the client side (RPC)
  #
  # Arguments
  # * host: hostname of the client
  # * port: port on which the client listen to Drb
  # * exec_specific: instance of Config.exec_specific
  # Output
  # * nothing
  def launch_workflow(host, port, exec_specific)
    puts "Let's launch an instance of Kadeploy"
    DRb.start_service()
    uri = "druby://#{host}:#{port}"
    client = DRbObject.new(nil, uri)

    #We create a new instance of Config with a specific exec_specific part
    config = ConfigInformation::Config.new("empty")
    config.common = @config.common
    config.exec_specific = exec_specific
    config.cluster_specific = Hash.new

    #Overide the configuration if the steps are specified in the command line
    if (not exec_specific.steps.empty?) then
      exec_specific.node_list.group_by_cluster.each_key { |cluster|
        config.cluster_specific[cluster] = ConfigInformation::ClusterSpecificConfig.new
        @config.cluster_specific[cluster].duplicate_but_steps(config.cluster_specific[cluster], exec_specific.steps)
      }
    #If the environment specifies a preinstall, we override the automata to use specific preinstall
    elsif (exec_specific.environment.preinstall != nil) then
      puts "A specific presinstall will be used with this environment"
      exec_specific.node_list.group_by_cluster.each_key { |cluster|
        config.cluster_specific[cluster] = ConfigInformation::ClusterSpecificConfig.new
        @config.cluster_specific[cluster].duplicate_all(config.cluster_specific[cluster])
        instance = config.cluster_specific[cluster].get_macro_step("SetDeploymentEnv").get_instance
        max_retries = instance[1]
        timeout = instance[2]
        config.cluster_specific[cluster].replace_macro_step("SetDeploymentEnv", ["SetDeploymentEnvUntrustedCustomPreInstall", max_retries, timeout])
      }
    else
      config.cluster_specific = @config.cluster_specific
    end

    workflow = Managers::WorkflowManager.new(config, client, @reboot_window, @nodes_check_window, @db, @deployments_table_lock, @syslog_lock)
    workflow_id = add_workflow_info(workflow)
    client.set_workflow_id(workflow_id)
    client.write_workflow_id(exec_specific.write_workflow_id) if exec_specific.write_workflow_id != ""
    finished = false
    tid = Thread.new {
      while (not finished) do
        begin
          client.test()
        rescue DRb::DRbConnError
          workflow.output.disable_client_output()
          workflow.output.verbosel(3, "Client disconnection")
          workflow.kill()
          finished = true
        end
        sleep(1)
      end
    }
    if (workflow.prepare() && workflow.manage_files()) then
      workflow.run_sync()
    end
    finished = true
    #let's free memory at the end of the workflow
    tid = nil
    delete_workflow_info(workflow_id)
    workflow.finalize
    workflow = nil
    exec_specific = nil
    client = nil
    DRb.stop_service()
    GC.start
  end


  # Launch the workflow in an asynchronous way (RPC)
  #
  # Arguments
  # * exec_specific: instance of Config.exec_specific
  # Output
  # * return a workflow id
  def launch_workflow_async(exec_specific)
    puts "Let's launch an instance of Kadeploy"

    #We create a new instance of Config with a specific exec_specific part
    config = ConfigInformation::Config.new("empty")
    config.common = @config.common
    config.exec_specific = exec_specific
    config.cluster_specific = Hash.new

    #Overide the configuration if the steps are specified in the command line
    if (not exec_specific.steps.empty?) then
      exec_specific.node_list.group_by_cluster.each_key { |cluster|
        config.cluster_specific[cluster] = ConfigInformation::ClusterSpecificConfig.new
        @config.cluster_specific[cluster].duplicate_but_steps(config.cluster_specific[cluster], exec_specific.steps)
      }
    #If the environment specifies a preinstall, we override the automata to use specific preinstall
    elsif (exec_specific.environment.preinstall != nil) then
      puts "A specific presinstall will be used with this environment"
      exec_specific.node_list.group_by_cluster.each_key { |cluster|
        config.cluster_specific[cluster] = ConfigInformation::ClusterSpecificConfig.new
        @config.cluster_specific[cluster].duplicate_all(config.cluster_specific[cluster])
        instance = config.cluster_specific[cluster].get_macro_step("SetDeploymentEnv").get_instance
        max_retries = instance[1]
        timeout = instance[2]
        config.cluster_specific[cluster].replace_macro_step("SetDeploymentEnv", ["SetDeploymentEnvUntrustedCustomPreInstall", max_retries, timeout])
      }
    else
      config.cluster_specific = @config.cluster_specific
    end

    workflow = Managers::WorkflowManager.new(config, nil, @reboot_window, @nodes_check_window, @db, @deployments_table_lock, @syslog_lock)
    workflow_id = add_workflow_info(workflow)
    if (workflow.prepare()) then
      workflow.run_async()
    end

    return workflow_id
  end

  # Test if the workflow has reached the end (RPC: only for async execution)
  #
  # Arguments
  # * id: worklfow id
  # Output
  # * return true if the workflow has reached the end, false otherwise
  def ended?(id)
    workflow = @workflow_info_hash[id]
    return workflow.ended?
  end

  # Get the results of a workflow (RPC: only for async execution)
  #
  # Arguments
  # * id: worklfow id
  # Output
  # * return a hastable containing the state of all the nodes involved in the deployment
  def get_results(id)
    workflow = @workflow_info_hash[id]
    return workflow.get_results
  end

  # Clean the stuff related to the deployment (RPC: only for async execution)
  #
  # Arguments
  # * id: worklfow id
  # Output
  # * nothing
  def free(id)
    workflow = @workflow_info_hash[id]
    #let's free memory at the end of the workflow
    tid = nil
    delete_workflow_info(id)
    workflow.finalize
    workflow = nil
    exec_specific = nil
    DRb.stop_service()
    GC.start
  end

  # Reboot a set of nodes from the client side (RPC)
  #
  # Arguments
  # * exec_specific: instance of Config.exec_specific
  # * host: hostname of the client
  # * port: port on which the client listen to Drb
  # * verbose_level: level of verbosity
  # * pxe_profile_msg: PXE profile
  # Output
  # * return 0 in case of success, 1 if the reboot failed on some nodes, 2 if the reboot has not been launched
  def launch_reboot(exec_specific, host, port, verbose_level, pxe_profile_msg)
    DRb.start_service()
    uri = "druby://#{host}:#{port}"
    client = DRbObject.new(nil, uri)
    ret = 0
    if (verbose_level != nil) then
      vl = verbose_level
    else
      vl = @config.common.verbose_level
    end
    @config.common.taktuk_connector = @config.common.taktuk_ssh_connector
    output = Debug::OutputControl.new(vl, false, client, exec_specific.true_user, -1, 
                                      @config.common.dbg_to_syslog, @config.common.dbg_to_syslog_level, @syslog_lock)
    if (exec_specific.reboot_kind == "env_recorded") && 
        exec_specific.check_prod_env && 
        exec_specific.node_list.check_demolishing_env(@db, @config.common.demolishing_env_threshold) then
      output.verbosel(0, "Reboot not performed since some nodes have been deployed with a demolishing environment")
      ret = 2
    else
      #We create a new instance of Config with a specific exec_specific part
      config = ConfigInformation::Config.new("empty")
      config.common = @config.common.clone
      config.cluster_specific = @config.cluster_specific.clone
      config.exec_specific = exec_specific
      exec_specific.node_list.group_by_cluster.each_pair { |cluster, set|
        step = MicroStepsLibrary::MicroSteps.new(set, Nodes::NodeSet.new, @reboot_window, @nodes_check_window, config, cluster, output, "Kareboot")
        case exec_specific.reboot_kind
        when "env_recorded"
          #This should be the same case than a deployed env
          step.switch_pxe("deploy_to_deployed_env")
        when "set_pxe"
          step.switch_pxe("set_pxe", pxe_profile_msg)
        when "simple_reboot"
          #no need to change the PXE profile
        when "deploy_env"
          step.switch_pxe("prod_to_deploy_env")
        else
          raise "Invalid kind of reboot: #{@reboot_kind}"
        end
        step.reboot(exec_specific.reboot_level)
        step.wait_reboot([@config.common.ssh_port],[])
        if (exec_specific.reboot_kind == "env_recorded") then
          part = String.new
          if (exec_specific.block_device == "") then
            part = get_block_device(cluster) + exec_specific.deploy_part
          else
            part = exec_specific.block_device + exec_specific.deploy_part
          end
          #Reboot on the production environment
          if (part == get_prod_part(cluster)) then
            set.set_deployment_state("prod_env", nil, @db, exec_specific.true_user)
            step.check_nodes("prod_env_booted")
            if (exec_specific.check_prod_env) then
              step.nodes_ko.tag_demolishing_env(@db)
              ret = 1
            end
          else
            set.set_deployment_state("recorded_env", nil, @db, exec_specific.true_user)
          end
        end
        if (exec_specific.reboot_kind == "deploy_env") then
          step.send_key_in_deploy_env("tree")
        end
      }
      config = nil
    end
    return ret
  end
end



begin
  config = ConfigInformation::Config.new("kadeploy")
rescue
  puts "Bad configuration"
  exit(1)
end
if (config.check_config("kadeploy") == true)
  db = Database::DbFactory.create(config.common.db_kind)
  Signal.trap("TERM") do
    puts "TERM trapped, let's clean everything ..."
    db.disconnect
    exit(1)
  end
  Signal.trap("INT") do
    puts "SIGINT trapped, let's clean everything ..."
    db.disconnect
    exit(1)
  end
  db.connect(config.common.deploy_db_host,
             config.common.deploy_db_login,
             config.common.deploy_db_passwd,
             config.common.deploy_db_name)
  kadeployServer = KadeployServer.new(config, 
                                      Managers::WindowManager.new(config.common.reboot_window, config.common.reboot_window_sleep_time),
                                      Managers::WindowManager.new(config.common.nodes_check_window, 1),
                                      db)
  puts "Launching the Kadeploy RPC server"
  uri = "druby://#{config.common.kadeploy_server}:#{config.common.kadeploy_server_port}"
  DRb.start_service(uri, kadeployServer)
  DRb.thread.join
else
  puts "Bad configuration"
end
