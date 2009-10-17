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
require 'digest/sha1'

class KadeployServer
  @config = nil
  @client = nil
  attr_reader :deployments_table_lock
  attr_reader :tcp_buffer_size
  attr_reader :dest_host
  attr_reader :dest_port
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
  # Output
  # * raises an exception if the file server can not open a socket
  def initialize(config, reboot_window, nodes_check_window)
    @config = config
    @dest_host = @config.common.kadeploy_server
    @tcp_buffer_size = @config.common.kadeploy_tcp_buffer_size
    @reboot_window = reboot_window
    @nodes_check_window = nodes_check_window
    @deployments_table_lock = Mutex.new
    @syslog_lock = Mutex.new
    @workflow_info_hash = Hash.new
    @workflow_info_hash_lock = Mutex.new
  end

  # Give the current version of Kadeploy (RPC)
  #
  # Arguments
  # * nothing
  # Output
  # * nothing
  def get_version
    return @config.common.version
  end

  # Record a Managers::WorkflowManager pointer
  #
  # Arguments
  # * workflow_ptr: reference toward a Managers::WorkflowManager
  # * workflow_id: workflow_id
  # Output
  # * nothing
  def add_workflow_info(workflow_ptr, workflow_id)
    @workflow_info_hash[workflow_id] = workflow_ptr
  end

  # Delete the information of a workflow
  #
  # Arguments
  # * workflow_id: workflow id
  # Output
  # * nothing
  def delete_workflow_info(workflow_id)
    @workflow_info_hash.delete(workflow_id)
  end

  # Get a YAML output of the workflows (RPC)
  #
  # Arguments
  # * workflow_id (opt): workflow id
  # Output
  # * return a string containing the YAML output
  def get_workflow_state(workflow_id = "")
    str = String.new
    @workflow_info_hash_lock.lock
    if (@workflow_info_hash.has_key?(workflow_id)) then
      hash = Hash.new
      hash[workflow_id] = @workflow_info_hash[workflow_id].get_state
      str = hash.to_yaml
      hash = nil
    elsif (workflow_id == "") then
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
  # * workflow_id: id of the workflow
  # Output
  # * nothing  
  def kill(workflow_id)
    # id == -1 means that the workflow has not been launched yet
    @workflow_info_hash_lock.lock
    if ((workflow_id != -1) && (@workflow_info_hash.has_key?(workflow_id))) then
      workflow = @workflow_info_hash[workflow_id]
      workflow.kill()
      delete_workflow_info(workflow_id)
    end
    @workflow_info_hash_lock.unlock
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

  def get_cluster_config(cluster)
    return @config.cluster_specific[cluster]
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
  # * return false if cannot connect to DB, true otherwise
  def launch_workflow(host, port, exec_specific)
    db = Database::DbFactory.create(@config.common.db_kind)
    if not db.connect(@config.common.deploy_db_host,
                      @config.common.deploy_db_login,
                      @config.common.deploy_db_passwd,
                      @config.common.deploy_db_name) then
      puts "Kadeploy server cannot connect to DB"
      return false
    end

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
      exec_specific.node_list.group_by_cluster.each_key { |cluster|
        config.cluster_specific[cluster] = ConfigInformation::ClusterSpecificConfig.new
        @config.cluster_specific[cluster].duplicate_all(config.cluster_specific[cluster])
      }
    end
    @workflow_info_hash_lock.lock
    workflow_id = Digest::SHA1.hexdigest(config.exec_specific.true_user + Time.now.to_s + exec_specific.node_list.to_s)
    workflow = Managers::WorkflowManager.new(config, client, @reboot_window, @nodes_check_window, db, @deployments_table_lock, @syslog_lock, workflow_id)
    add_workflow_info(workflow, workflow_id)
    @workflow_info_hash_lock.unlock
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
    if (workflow.prepare() && workflow.manage_files(false)) then
      workflow.run_sync()
    else
      workflow.output.verbosel(0, "Cannot run the deployment")
    end
    finished = true
    #let's free memory at the end of the workflow
    db.disconnect
    tid = nil
    @workflow_info_hash_lock.lock
    delete_workflow_info(workflow_id)
    @workflow_info_hash_lock.unlock
    workflow.finalize
    workflow = nil
    exec_specific = nil
    client = nil
    config = nil
    DRb.stop_service()
    GC.start
    return true
  end


  # Launch the workflow in an asynchronous way (RPC)
  #
  # Arguments
  # * exec_specific: instance of Config.exec_specific
  # Output
  # * return a workflow id(, or nil if all the nodes have been discarded) and an integer (0: no error, 1: nodes discarded, 2: some files cannot be grabbed, 3: server cannot connect to DB)
  def launch_workflow_async(exec_specific)
    db = Database::DbFactory.create(@config.common.db_kind)
    if not db.connect(@config.common.deploy_db_host,
                      @config.common.deploy_db_login,
                      @config.common.deploy_db_passwd,
                      @config.common.deploy_db_name) then
      puts "Kadeploy server cannot connect to DB"
      return nil, 3
    end

    puts "Let's launch an instance of Kadeploy (async)"

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
      exec_specific.node_list.group_by_cluster.each_key { |cluster|
        config.cluster_specific[cluster] = ConfigInformation::ClusterSpecificConfig.new
        @config.cluster_specific[cluster].duplicate_all(config.cluster_specific[cluster])
      }
    end
    @workflow_info_hash_lock.lock
    workflow_id = Digest::SHA1.hexdigest(config.exec_specific.true_user + Time.now.to_s + exec_specific.node_list.to_s)
    workflow = Managers::WorkflowManager.new(config, nil, @reboot_window, @nodes_check_window, db, @deployments_table_lock, @syslog_lock, workflow_id)
    add_workflow_info(workflow, workflow_id)
    @workflow_info_hash_lock.unlock
    if workflow.prepare() then
      if workflow.manage_files(true) then
        workflow.run_async()
        return workflow_id, 0
      else
        free(workflow_id)
        return nil, 2 # some files cannot be grabbed
      end
    else
      free(workflow_id)
      return nil, 1 # all the nodes are involved in another deployment
    end
  end

  # Test if the workflow has reached the end (RPC: only for async execution)
  #
  # Arguments
  # * workflow_id: worklfow id
  # Output
  # * return true if the workflow has reached the end, false if not, and nil if the workflow does not exist
  def ended?(workflow_id)
    @workflow_info_hash_lock.lock
    if @workflow_info_hash.has_key?(workflow_id) then
      workflow = @workflow_info_hash[workflow_id]
      ret = workflow.ended?
    else
      ret = nil
    end
    @workflow_info_hash_lock.unlock
    return ret
  end

  # Get the results of a workflow (RPC: only for async execution)
  #
  # Arguments
  # * workflow_id: worklfow id
  # Output
  # * return a hastable containing the state of all the nodes involved in the deployment or nil if the workflow does not exist
  def get_results(workflow_id)
    @workflow_info_hash_lock.lock
    if @workflow_info_hash.has_key?(workflow_id) then
      workflow = @workflow_info_hash[workflow_id]
      ret = workflow.get_results
    else
      ret = nil
    end
    @workflow_info_hash_lock.unlock
    return ret
  end

  # Clean the stuff related to the deployment (RPC: only for async execution)
  #
  # Arguments
  # * id: worklfow id
  # Output
  # * nothing
  def free(workflow_id)
    @workflow_info_hash_lock.lock
    if @workflow_info_hash.has_key?(workflow_id) then
      workflow = @workflow_info_hash[workflow_id]
      workflow.db.disconnect
      delete_workflow_info(workflow_id)
      #let's free memory at the end of the workflow
      tid = nil
      workflow.finalize
      workflow = nil
      exec_specific = nil
      GC.start
      ret = true
    else
      ret = nil
    end
    @workflow_info_hash_lock.unlock
    return ret
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
  # * return 0 in case of success, 1 if the reboot failed on some nodes, 2 if the reboot has not been launched, 3 if the server cannot connect to DB
  def launch_reboot(exec_specific, host, port, verbose_level, pxe_profile_msg)
    db = Database::DbFactory.create(@config.common.db_kind)
    if not db.connect(@config.common.deploy_db_host,
                      @config.common.deploy_db_login,
                      @config.common.deploy_db_passwd,
                      @config.common.deploy_db_name) then
      puts "Kadeploy server cannot connect to DB"
      return 3
    end

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
        exec_specific.node_list.check_demolishing_env(db, @config.common.demolishing_env_threshold) then
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
        if exec_specific.wait then
          if (exec_specific.reboot_kind == "deploy_env") then
            step.wait_reboot([@config.common.ssh_port,@config.common.test_deploy_env_port],[])
            step.send_key_in_deploy_env("tree")
            set.set_deployment_state("deploy_env", nil, db, exec_specific.true_user)
          else
            step.wait_reboot([@config.common.ssh_port],[])
          end
          if (exec_specific.reboot_kind == "env_recorded") then
            part = String.new
            if (exec_specific.block_device == "") then
              part = get_block_device(cluster) + exec_specific.deploy_part
            else
              part = exec_specific.block_device + exec_specific.deploy_part
            end
            #Reboot on the production environment
            if (part == get_prod_part(cluster)) then
              set.set_deployment_state("prod_env", nil, db, exec_specific.true_user)
              if (exec_specific.check_prod_env) then
                step.nodes_ko.tag_demolishing_env(db) if config.common.demolishing_env_auto_tag
                ret = 1
              end
            else
              set.set_deployment_state("recorded_env", nil, db, exec_specific.true_user)
            end
          end
          if not step.nodes_ok.empty? then
            output.verbosel(0, "Nodes correctly rebooted:")
            output.verbosel(0, step.nodes_ok.to_s(false, "\n"))
          end
          if not step.nodes_ko.empty? then
            output.verbosel(0, "Nodes not correctly rebooted:")
            output.verbosel(0, step.nodes_ko.to_s(true, "\n"))
          end
          client.generate_files(step.nodes_ok, config.exec_specific.nodes_ok_file, step.nodes_ko, config.exec_specific.nodes_ko_file)
        end
      }
    end
    db.disconnect
    config = nil
    return ret
  end
end


begin
  config = ConfigInformation::Config.new("kadeploy")
rescue
  puts "Bad configuration: #{$!}"
  exit(1)
end
if (config.check_config("kadeploy") == true)
  db = Database::DbFactory.create(config.common.db_kind)
  Signal.trap("TERM") do
    puts "TERM trapped, let's clean everything ..."
    exit(1)
  end
  Signal.trap("INT") do
    puts "SIGINT trapped, let's clean everything ..."
    exit(1)
  end
  if not db.connect(config.common.deploy_db_host,
                    config.common.deploy_db_login,
                    config.common.deploy_db_passwd,
                    config.common.deploy_db_name)
    puts "Cannot connect to the database"
    exit(1)
  else
    db.disconnect
    kadeployServer = KadeployServer.new(config, 
                                        Managers::WindowManager.new(config.common.reboot_window, config.common.reboot_window_sleep_time),
                                        Managers::WindowManager.new(config.common.nodes_check_window, 1))
    puts "Launching the Kadeploy RPC server"
    uri = "druby://#{config.common.kadeploy_server}:#{config.common.kadeploy_server_port}"
    DRb.start_service(uri, kadeployServer)
    DRb.thread.join
  end
else
  puts "Bad configuration"
end
