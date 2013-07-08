#!/usr/bin/ruby -w

# Kadeploy 3.1
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2012
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

DEPLOYMENT_STATUS_CHECK_PITCH=2
RESULTS_PRINT_PITCH=200
RESULTS_MAX_PER_REQUEST=20000

Signal.trap("TERM") do
  puts "TERM trapped, let's clean everything ..."
  exit(1)
end
Signal.trap("INT") do
  puts "SIGINT trapped, let's clean everything ..."
  exit(1)
end

#Kadeploy libs
require 'workflow'
require 'debug'
require 'microsteps'
require 'process_management'
require 'grabfile'
require 'error'

#Ruby libs
require 'drb'
require 'socket'
require 'yaml'
require 'digest/sha1'
require 'uri'

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
  @workflow_info_hash = nil
  @workflow_info_hash_lock = nil
  @reboot_info_hash = nil
  @reboot_info_hash_lock = nil
  @power_info_hash = nil
  @power_info_hash_lock = nil
  @kasyncs = nil

  undef :instance_eval
  undef :eval

  public
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
    @reboot_info_hash = Hash.new
    @reboot_info_hash_lock = Mutex.new
    @power_info_hash = Hash.new
    @power_info_hash_lock = Mutex.new
    @kasyncs = Hash.new
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

  def get_users_info
    ret = {}

    ret[:pxe] = @config.common.pxe[:dhcp].class.name.split('::').last
    ret[:supported_fs] = {}
    @config.cluster_specific.each_pair do |cluster,conf|
      ret[:supported_fs][cluster] = conf.deploy_supported_fs
    end
    ret[:vars] = Microstep.load_deploy_context().keys.sort
    return ret
  end

  # Check if the server knows a set of nodes (RPC)
  #
  # Arguments
  # * nodes: array of hostnames
  # Output
  # * returns an array with known nodes and another one with unknown nodes
  def check_known_nodes(nodes)
    node_list = Array.new
    nodes_ok = Array.new
    nodes_ko = Array.new
    nodes.each { |n|
      if Nodes::REGEXP_NODELIST =~ n
         node_list = node_list + Nodes::NodeSet::nodes_list_expand("#{n}")
      else
        node_list.push(n)
      end
    }
    node_list.each { |n|
      if (@config.common.nodes_desc.get_node_by_host(n) != nil) then
          nodes_ok.push(n)
      else
        nodes_ko.push(n)
      end
    }
    return [nodes_ok,nodes_ko]
  end

  # Create a socket server designed to copy a file from to client to the server cache (RPC)
  #
  # Arguments
  # * filename: name of the destination file
  # * cache_dir: cache directory
  # Output
  # * return the port allocated to the socket server
  def create_socket_server(dest,filesize)
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
        totwrite = 0
        totrecv = 0
        session = sock.accept
        file = File.new(dest, "w")
        while (totrecv < filesize)
          buf = session[0].recv(@tcp_buffer_size)
          totrecv += buf.size
          totwrite += file.write(buf)
        end
        file.close
        session[0].send([totwrite].pack('L'),0)
        session[0].close
      rescue Exception => e
        puts "The client has been probably disconnected... (#{e.class.name}: #{e.message})"
      end
      sock.close
    }
    return port
  end
  
  # Run a command on the server (RPC)
  #
  # Arguments
  # * kind: kind of command (kadeploy_async, kadeploy_sync, kareboot, kastat, kanodes, karights, kaenv, kaconsole)
  # * exec_specific_config: instance of Config.exec_specific
  # * host: hostname of the client
  # * post: port of the client
  # Output
  # * kadeploy_async, kareboot_async: return a couple of value (id,error_code) id is nil in case of problem
  # * other kinds: return true if the command has been correctly performed, false otherwise
  def run(kind, exec_specific_config, host, port)
    db = Database::DbFactory.create(@config.common.db_kind)
    unless db.connect(
      @config.common.deploy_db_host,
      @config.common.deploy_db_login,
      @config.common.deploy_db_passwd,
      @config.common.deploy_db_name)
    then
      distant = DRb.start_service("druby://localhost:0")
      uri = "druby://#{host}:#{port}"
      client = DRbObject.new(nil, uri)
      Debug::distant_client_error("Kadeploy server cannot connect to DB #{@config.common.deploy_db_login}@#{@config.common.deploy_db_host}/#{@config.common.deploy_db_name}",client)
      client.print('Please contact the administration team.')
      distant.stop_service()
      return false
    end

    if ((kind == "kadeploy_sync") || (kind == "kadeploy_async") ||
        (kind == "kareboot_sync") || (kind == "kareboot_async")) &&
        (exec_specific_config.pxe_profile_singularities != nil) then
      h = Hash.new
      exec_specific_config.pxe_profile_singularities.each { |hostname, val|
        n = @config.common.nodes_desc.get_node_by_host(hostname)
        if (n == nil) then
          if (kind == "kadeploy_sync") || (kind == "kareboot_sync") then
            distant = DRb.start_service("druby://localhost:0")
            uri = "druby://#{host}:#{port}"
            client = DRbObject.new(nil, uri)
            client.print("ERROR: The node #{hostname} specified in the PXE singularity file does not exist")
            distant.stop_service()
            db.disconnect
            return false
          else
            case kind
            when "kadeploy_async"
              return nil, KadeployAsyncError::UNKNOWN_NODE_IN_SINGULARITY_FILE
            when "kareboot_async"
              return nil, KarebootAsyncError::UNKNOWN_NODE_IN_SINGULARITY_FILE
            end
          end
        else
          h[n.ip] = val
        end
      }
      exec_specific_config.pxe_profile_singularities.clear
      exec_specific_config.pxe_profile_singularities = h
    end

    if ((kind == "kadeploy_async") || (kind == "kareboot_async") || (kind == "kapower_async")) then
      res = @config.check_client_config(kind, exec_specific_config, db, nil)
      if ((res == KarebootAsyncError::NO_ERROR) || (res == KadeployAsyncError::NO_ERROR) || (res == 0)) then
        method = "run_#{kind}".to_sym
        return send(method, db, exec_specific_config)
      else
        db.disconnect
        return nil, res
      end
    else
      distant = DRb.start_service("druby://localhost:0")
      uri = "druby://#{host}:#{port}"
      client = DRbObject.new(nil, uri)
      res = @config.check_client_config(kind, exec_specific_config, db, client)
      if ((res == KarebootAsyncError::NO_ERROR) || (res == KadeployAsyncError::NO_ERROR) || (res == 0)) then
        method = "run_#{kind}".to_sym
        res = send(method, db, client, exec_specific_config, distant)        
      else
        res = false
      end
      db.disconnect
      exec_specific_config = nil
      distant.stop_service()
      client = nil
      begin
        GC.start
      rescue TypeError
      end
      return res
    end
  end

  # Test if the workflow has reached the end (RPC: only for async execution)
  #
  # Arguments
  # * workflow_id: worklfow id
  # Output
  # * return true if the workflow has reached the end, false if not, and nil if the workflow does not exist
  def async_deploy_ended?(workflow_id)
    return async_deploy_lock_wid(workflow_id) { |info|
      res = true
      info[:workflows].each do |workflow|
        res = res && workflow.done?
        break unless res
      end
      res
    }
  end

  # Test if the workflow encountered an error while grabbing files (RPC: only for async execution)
  #
  # Arguments
  # * workflow_id: worklfow id
  # Output
  # * return true if the workflow encountered and error, false if not, and nil if the workflow does not exist
  def async_deploy_file_error?(workflow_id)
    return async_deploy_lock_wid(workflow_id) { |info|
      res = FetchFileError::NO_ERROR
      info[:workflows].each do |workflow|
        res = workflow.errno
        break if res
      end

      if info[:grabthread] and !info[:grabthread].alive?
        begin
          info[:grabthread].join
        rescue KadeployError => ke
          res = ke.errno
        end
      end
      res || FetchFileError::NO_ERROR
    }
  end

  def async_deploy_get_status(workflow_id)
    ret = {}
    async_deploy_lock_wid(workflow_id) do |info|
      info[:workflows].each do |workflow|
        ret[workflow.context[:cluster].prefix] = workflow.status
      end
    end
    ret
  end

  # Get the results of a workflow (RPC: only for async execution)
  #
  # Arguments
  # * workflow_id: worklfow id
  # Output
  # * return a hastable containing the state of all the nodes involved in the deployment or nil if the workflow does not exist
  def async_deploy_get_results(workflow_id)
    nodes_ok = Nodes::NodeSet.new
    nodes_ko = Nodes::NodeSet.new

    async_deploy_lock_wid(workflow_id) do |info|
      info[:workflows].each do |workflow|
        nodes_ok.add(workflow.nodes_ok)
        nodes_ok.add(workflow.nodes_brk)
        nodes_ko.add(workflow.nodes_ko)
      end
    end

    return {
      'nodes_ok' => nodes_ok.to_h,
      'nodes_ko' => nodes_ko.to_h,
    }
  end

  # Clean the stuff related to the deployment (RPC: only for async execution)
  #
  # Arguments
  # * workflow_id: worklfow id
  # Output
  # * return true if the deployment has been freed and nil if workflow id does no exist
  def async_deploy_free(workflow_id)
    return async_deploy_lock_wid(workflow_id) { |info|
      context = info[:workflows].first.context if info[:workflows].first

      # Unlock the cached files
      if info[:cached_files]
        info[:cached_files].each do |file|
          file.release
        end
      end

      # Clean cache
      @config.common.cache[:global].clean  if @config.common.cache[:global]
      @config.common.cache[:netboot].clean

      info[:database].disconnect if info[:database]
      kadeploy_delete_workflow_info(workflow_id)
      true
    }
  end

  # Kill a workflow (RPC)
  #
  # Arguments
  # * workflow_id: id of the workflow
  # Output
  # * return true if the deployment has been killed and nil if workflow id does no exist
  def async_deploy_kill(workflow_id)
    ret = async_deploy_lock_wid(workflow_id) { |info|
      info[:workflows].each do |workflow|
        workflow.kill()
      end
      info[:exec_specific].node_set.set_deployment_state('aborted', nil, info[:database], info[:user])
      true
    }
    async_deploy_free(workflow_id)
    return ret
  end

  # Test if the power operation has reached the end (RPC: only for async execution)
  #
  # Arguments
  # * power_id: power id
  # Output
  # * return true if the power operation has reached the end, false if not, and nil if the power id does not exist
  def async_power_ended?(power_id)
    r = nil
    @power_info_hash_lock.synchronize {
      r = @power_info_hash[power_id][2] if @power_info_hash.has_key?(power_id)
    }
    return r
  end

  # Clean the stuff related to a power operation (RPC: only for async execution)
  #
  # Arguments
  # * power_id: power id
  # Output
  # * return true if the power operation has been freed and nil if power id does no exist
  def async_power_free(power_id)
    r = nil
    @power_info_hash_lock.synchronize {
      if @power_info_hash.has_key?(power_id) then
        @power_info_hash[power_id][0].free()
        @power_info_hash[power_id][1].free()
        kapower_delete_power_info(power_id)
        r = true
      end
    }
    return r
  end

  # Get the results of a power operation (RPC: only for async execution)
  #
  # Arguments
  # * power_id: power id
  # Output
  # * return an array containing two arrays (0: nodes_ok, 1: nodes_ko) or nil if the power id does not exist
  def async_power_get_results(power_id)
    if @power_info_hash.has_key?(power_id) then
      return {
        'nodes_ok' => @power_info_hash[power_id][0].to_h,
        'nodes_ko' => @power_info_hash[power_id][1].to_h
      }
    else
      return nil
    end
  end

  # Test if the reboot operation has reached the end (RPC: only for async execution)
  #
  # Arguments
  # * reboot_id: reboot id
  # Output
  # * return true if the reboot operation has reached the end, false if not, and nil if the reboot id does not exist
  def async_reboot_ended?(reboot_id)
    r = nil
    @reboot_info_hash_lock.synchronize {
      if @reboot_info_hash.has_key?(reboot_id)
        r = @reboot_info_hash[reboot_id][2]
      end
    }
    return r
  end

  # Clean the stuff related to a reboot operation (RPC: only for async execution)
  #
  # Arguments
  # * reboot_id: reboot id
  # Output
  # * return true if the reboot operation has been freed and nil if reboot id does no exist
  def async_reboot_free(reboot_id)
    @reboot_info_hash_lock.synchronize {
      if @reboot_info_hash.has_key?(reboot_id) then
        @reboot_info_hash[reboot_id][0].free()
        @reboot_info_hash[reboot_id][1].free()
        # Unlock the cached files
        if @reboot_info_hash[reboot_id].size >= 4
          @reboot_info_hash[reboot_id][4].each do |file|
            file.release
          end
        end
        kareboot_delete_reboot_info(reboot_id)
      end
    }
    # Clean cache
    @config.common.cache[:global].clean  if @config.common.cache[:global]
    @config.common.cache[:netboot].clean
  end

  # Get the results of a reboot operation (RPC: only for async execution)
  #
  # Arguments
  # * reboot_id: reboot id
  # Output
  # * return an array containing two arrays (0: nodes_ok, 1: nodes_ko) or nil if the reboot id does not exist
  def async_reboot_get_results(reboot_id)
    if @reboot_info_hash.has_key?(reboot_id) then
      return {
        'nodes_ok' => @reboot_info_hash[reboot_id][0].to_h,
        'nodes_ko' => @reboot_info_hash[reboot_id][1].to_h
      }
    else
      return nil
    end
  end

  def create_kasync(id)
    @kasyncs[id] = Mutex.new
  end

  def kasync(id)
    if block_given?
      @kasyncs[id].synchronize{ yield }
    else
      @kasyncs[id].synchronize{}
    end
  end

  def delete_kasync(wid)
    @kasyncs.delete(wid)
  end


  private
  def run_kadeploy(db, exec_specific, client=nil)
    config = ConfigInformation::Config.new(true)
    config.common = @config.common
    config.exec_specific = exec_specific
    config.cluster_specific = Hash.new

    exec_specific.node_set.group_by_cluster.each_key do |cluster|
      config.cluster_specific[cluster] =
        ConfigInformation::ClusterSpecificConfig.new
      @config.cluster_specific[cluster].duplicate_all(
        config.cluster_specific[cluster]
      )
    end

    context = {
      :deploy_id => nil,
      :user => exec_specific.true_user,
      :database => db,
      :client => client,
      :syslock => @syslog_lock,
      :dblock => @deployments_table_lock,
      :config => config,
      :common => config.common,
      :execution => config.exec_specific,
      :windows => {
        :reboot => @reboot_window,
        :check => @nodes_check_window,
      },
      :nodesets_id => 0,
      :async => client.nil?,
    }

    @workflow_info_hash_lock.lock
    workflow_id = Digest::SHA1.hexdigest(
      config.exec_specific.true_user \
      + Time.now.to_s \
      + exec_specific.node_set.to_s
    )
    kadeploy_create_workflow_info(workflow_id)
    @workflow_info_hash[workflow_id][:exec_specific] = exec_specific
    @workflow_info_hash[workflow_id][:database] = db
    @workflow_info_hash[workflow_id][:user] = exec_specific.true_user
    context[:deploy_id] = workflow_id

    tmpoutput = nil
    unless context[:common].kadeploy_disable_cache
      tmpoutput = Debug::OutputControl.new(
        context[:execution].verbose_level || context[:common].verbose_level,
        context[:execution].debug,
        context[:client],
        context[:execution].true_user,
        context[:deploy_id],
        context[:common].dbg_to_syslog,
        context[:common].dbg_to_syslog_level,
        context[:syslock],
        ''
      )

      @workflow_info_hash[workflow_id][:grabthread] = Thread.new do
        begin
          @workflow_info_hash[workflow_id][:cached_files] =
            Managers::GrabFileManager.grab_user_files(context,tmpoutput)
        rescue KadeployError => ke
          exec_specific.node_set.set_deployment_state('aborted',nil,context[:database],context[:user])
          raise KadeployError.new(ke.errno,{ :wid => workflow_id },ke.message)
        end
      end
    end

    workflows = []
    clusters = exec_specific.node_set.group_by_cluster
    if clusters.size > 1
      clid = 1
    else
      clid = 0
    end
    clusters.each_pair do |cluster,nodeset|
      context[:cluster] = config.cluster_specific[cluster]
      if clusters.size > 1
        if context[:cluster].prefix.empty?
          context[:cluster].prefix = "c#{clid}"
          clid += 1
        end
      else
        context[:cluster].prefix = ''
      end

      begin
        workflow = Workflow.new(nodeset,context.dup)
      rescue KadeployError => ke
        @workflow_info_hash_lock.unlock
        raise KadeployError.new(ke.errno,{ :wid => workflow_id },ke.message)
      end
      kadeploy_add_workflow_info(workflow, workflow_id)
      workflows << workflow
    end
    @workflow_info_hash_lock.unlock

    if clusters.size > 1
      tmp = ''
      workflows.each do |workflow|
        tmp += "  #{Debug.prefix(workflow.context[:cluster].prefix)}: #{workflow.context[:cluster].name}\n"
      end
      client.print("\nClusters involved in the deployment:\n#{tmp}\n") if client
    end

    # Run workflows
    if block_given?
      begin
        yield(workflow_id,workflows)
      ensure
        #let's free memory at the end of the workflow
        @workflow_info_hash_lock.synchronize {
          # Unlock the cached files
          if @workflow_info_hash[workflow_id] and @workflow_info_hash[workflow_id][:cached_files]
            @workflow_info_hash[workflow_id][:cached_files].each do |file|
              file.release
            end
          end

          kadeploy_delete_workflow_info(workflow_id)
        }
        # Clean cache
        @config.common.cache[:global].clean if @config.common.cache[:global]
        @config.common.cache[:netboot].clean
        config = nil
      end
      true
    else
      [workflow_id,workflows]
    end
  end

  ##################################
  #         Kadeploy Sync          #
  ##################################

  # Launch the Kadeploy workflow from the client side
  #
  # Arguments
  # * db: database handler
  # * client: DRb handler of the Kadeploy client
  # * exec_specific: instance of Config.exec_specific
  # Output
  # * return true
  def run_kadeploy_sync(db, client, exec_specific, drb_server)
    begin
      run_kadeploy(db,exec_specific,client) do |wid,workflows|
        # Prepare client
        client.set_workflow_id(wid)
        client.write_workflow_id(exec_specific.write_workflow_id) if exec_specific.write_workflow_id != ""

        # Client disconnection fallback
        finished = false
        finthr = Thread.new do
          while (not finished) do
            begin
              client.test()
            rescue DRb::DRbConnError
              workflows.each do |workflow|
                workflow.output.disable_client_output()
              end
              workflows.first.output.verbosel(3, "Client disconnection")
              kadeploy_sync_kill_workflow(wid)
              drb_server.stop_service()
              db.disconnect()
              finished = true
            end
            sleep(1)
          end
        end

        # Wait that every files are cached
        @workflow_info_hash[wid][:grabthread].join if @workflow_info_hash[wid][:grabthread]

        # Run workflows
        threads = {}
        workflows.each { |workflow| threads[workflow] = workflow.run! }
        workflows.each { |workflow| sleep(0.2) until (workflow.cleaner) }
        dones = []
        until (dones.size >= workflows.size)
          workflows.each do |workflow|
            if !dones.include?(workflow) and workflow.done?
              threads[workflow].join
              dones << workflow
            else
              workflow.cleaner.join if workflow.cleaner and !workflow.cleaner.alive?
            end
          end
          sleep(DEPLOYMENT_STATUS_CHECK_PITCH)
        end
        workflows.each do |workflow|
          clname = workflow.context[:cluster].name
          client.print("")
          unless workflow.nodes_brk.empty?
            client.print("Nodes breakpointed on cluster #{clname}")
            client.print(workflow.nodes_brk.to_s(false,false,"\n"))
          end
          unless workflow.nodes_ok.empty?
            client.print("Nodes correctly deployed on cluster #{clname}")
            client.print(workflow.nodes_ok.to_s(false,false,"\n"))
          end
          unless workflow.nodes_ko.empty?
            client.print("Nodes not correctly deployed on cluster #{clname}")
            client.print(workflow.nodes_ko.to_s(false,true,"\n"))
          end
        end
        finished = true
        finthr.join
      end
    rescue KadeployError => ke
      msg = KadeployError.to_msg(ke.errno)
      Debug::distant_client_error("#{msg} (error ##{ke.errno})",client) if msg and !msg.empty?
      client.print(ke.message) if ke.message and !ke.message.empty?
      #Debug::distant_client_error("Cannot run the deployment",client)
      kadeploy_sync_kill_workflow(ke.context[:wid],false)
    rescue Exception => e
      puts e.message
      puts e.backtrace
      raise e
    end
    return true
  end

  # Kill a workflow (RPC)
  #
  # Arguments
  # * workflow_id: id of the workflow
  # Output
  # * nothing  
  def kadeploy_sync_kill_workflow(workflow_id,killrun=true)
    # id == -1 means that the workflow has not been launched yet
    @workflow_info_hash_lock.synchronize {
      if ((workflow_id != -1) && (@workflow_info_hash.has_key?(workflow_id))) then
        @workflow_info_hash[workflow_id][:runthread].kill \
          if @workflow_info_hash[workflow_id][:runthread].alive? and killrun
        #@workflow_info_hash[workflow_id][:runthread].join
        @workflow_info_hash[workflow_id][:grabthread].kill \
          if @workflow_info_hash[workflow_id][:grabthread] \
          and @workflow_info_hash[workflow_id][:grabthread].alive? and killrun
        #@workflow_info_hash[workflow_id][:grabthread].join

        @workflow_info_hash[workflow_id][:workflows].each do |workflow|
          workflow.kill()
        end
        if @workflow_info_hash[workflow_id][:cached_files]
          @workflow_info_hash[workflow_id][:cached_files].each do |file|
            file.release
          end
        end
        @config.common.cache[:global].clean if @config.common.cache[:global]
        @config.common.cache[:netboot].clean
        if @workflow_info_hash[workflow_id][:exec_specific]
          @workflow_info_hash[workflow_id][:exec_specific].node_set.set_deployment_state(
            'aborted',
            nil,
            @workflow_info_hash[workflow_id][:database],
            @workflow_info_hash[workflow_id][:user]
          )
        end
        @workflow_info_hash[workflow_id][:database].disconnect if @workflow_info_hash[workflow_id][:database]
        kadeploy_delete_workflow_info(workflow_id)
      end
    }
  end

  def kadeploy_create_workflow_info(workflow_id)
    @workflow_info_hash[workflow_id] = {}
    @workflow_info_hash[workflow_id][:runthread] = Thread.current
    @workflow_info_hash[workflow_id][:grabthread] = nil
    @workflow_info_hash[workflow_id][:workflows] = []
    @workflow_info_hash[workflow_id][:cached_files] = []
    @workflow_info_hash[workflow_id][:exec_specific] = nil
    @workflow_info_hash[workflow_id][:database] = nil
    @workflow_info_hash[workflow_id][:user] = nil
  end

  # Record a Managers::WorkflowManager pointer
  #
  # Arguments
  # * workflow_ptr: reference toward a Managers::WorkflowManager
  # * workflow_id: workflow_id
  # Output
  # * nothing
  def kadeploy_add_workflow_info(workflow_ptr, workflow_id)
    @workflow_info_hash[workflow_id][:workflows] << workflow_ptr
  end

  # Delete the information of a workflow
  #
  # Arguments
  # * workflow_id: workflow id
  # Output
  # * nothing
  def kadeploy_delete_workflow_info(workflow_id)
    if @workflow_info_hash[workflow_id]
      if @workflow_info_hash[workflow_id][:workflows]
        @workflow_info_hash[workflow_id][:workflows].each do |workflow|
          workflow.free
          workflow = nil
        end
      end
      if @workflow_info_hash[workflow_id][:exec_specific]
        ConfigInformation::Config.free_kadeploy_exec_specific(
          @workflow_info_hash[workflow_id][:exec_specific]
        )
      end
      @workflow_info_hash.delete(workflow_id)
      begin
        GC.start
      rescue TypeError
      end
    end
  end

  ##################################
  #        Kadeploy Async          #
  ##################################

  # Launch the workflow in an asynchronous way
  #
  # Arguments
  # * db: database handler
  # * exec_specific: instance of Config.exec_specific
  # Output
  # * return a workflow (id, or nil if all the nodes have been discarded) and an integer (0: no error, 1: nodes discarded)
  def run_kadeploy_async(db, exec_specific)
    wid, workflows = nil
    begin
      wid, workflows = run_kadeploy(db,exec_specific)
    rescue KadeployError => ke
      async_deploy_kill(ke.context[:wid])
      async_deploy_free(ke.context[:wid])
      return nil, ke.errno
    end

    info = @workflow_info_hash[wid]
    workflows.each do |workflow|
      workflow.run!{ info[:grabthread].join if info[:grabthread] }
    end

    if info[:grabthread] and !info[:grabthread].alive?
      begin
        info[:grabthread].join
      rescue KadeployError => ke
        async_deploy_free(wid)
        return nil, ke.errno
      end
    end

    return wid, KadeployAsyncError::NO_ERROR
  end

  # Take a lock on the workflow_info_hash and execute a block with the given workflow_id
  #
  # Arguments
  # * workflow_id: workflow id
  # Output
  # * return the result of the block or nil if the workflow_id does not exist
  def async_deploy_lock_wid(workflow_id)
    @workflow_info_hash_lock.lock
    if @workflow_info_hash.has_key?(workflow_id) then
      info = @workflow_info_hash[workflow_id]
      ret = yield(info)
    else
      ret = nil
    end
    @workflow_info_hash_lock.unlock
    return ret
  end


  ##################################
  #         Kareboot Sync          #
  ##################################

  def run_kareboot(output, db, exec_specific, client=nil)
    nodes_ok = Nodes::NodeSet.new
    nodes_ko = Nodes::NodeSet.new
    global_nodes_mutex = Mutex.new
    threads = []

    #We create a new instance of Config with a specific exec_specific part
    config = ConfigInformation::Config.new("empty")
    config.common = @config.common.clone
    config.exec_specific = exec_specific
    config.cluster_specific = Hash.new

    exec_specific.node_set.group_by_cluster.each_key do |cluster|
      config.cluster_specific[cluster] =
        ConfigInformation::ClusterSpecificConfig.new
      @config.cluster_specific[cluster].duplicate_all(
        config.cluster_specific[cluster]
      )
    end

    reboot_id = Digest::SHA1.hexdigest(
      config.exec_specific.true_user \
      + Time.now.to_s \
      + exec_specific.node_set.to_s
    )

    @reboot_info_hash_lock.synchronize {
      kareboot_add_reboot_info(reboot_id, nodes_ok, nodes_ko, false)
    }

    context = {
      :reboot_id => reboot_id,
      :database => db,
      :client => client,
      :syslock => @syslog_lock,
      :dblock => @deployments_table_lock,
      :config => config,
      :common => config.common,
      :execution => config.exec_specific,
      :windows => {
        :reboot => @reboot_window,
        :check => @nodes_check_window,
      },
      :nodesets_id => 0,
      :local => { :parent => KadeployServer, :retries => 0 }
    }

    if (exec_specific.reboot_kind == "env_recorded") \
      and exec_specific.check_demolishing \
      and exec_specific.node_set.check_demolishing_env(db)
    then
      output.verbosel(0, "Reboot not performed since some nodes have been "\
        "deployed with a demolishing environment")
      raise KadeployError.new(KarebootAsyncError::DEMOLISHING_ENV,
        :rid => reboot_id, :status => 2)
    end

    files = []
    if (exec_specific.reboot_kind == "set_pxe") and (!exec_specific.pxe_upload_files.empty?) then
      gfm = Managers::GrabFileManager.new(context[:common].cache[:netboot],
        output,client,db,744)

      exec_specific.pxe_upload_files.each do |pxefile|
        begin
          Managers::GrabFileManager::grab(gfm,context,pxefile,:anon,'pxe',
            KarebootAsyncError::PXE_FILE_FETCH_ERROR,
            :file => File.join(context[:common].cache[:netboot].directory,
              (
                NetBoot.custom_prefix(
                  context[:execution].true_user,
                  context[:reboot_id]
                ) + '--' + File.basename(pxefile)
              )
            )
          )
        rescue KadeployError => ke
          gfm.clean
          raise KadeployError.new(KarebootAsyncError::PXE_FILE_FETCH_ERROR,
            { :rid => ke.context[:rid], :status => 3}, ke.message)
        end
      end
      files += gfm.files
      gfm = nil
    end
    if (exec_specific.key != "") and (exec_specific.reboot_kind == "deploy_env")
      begin
        gfm = Managers::GrabFileManager.new(context[:common].cache[:global],
          output,client,db, 640)
        Managers::GrabFileManager::grab(gfm,context,exec_specific.key,:anon,
          'key',FetchFileError::INVALID_KEY)
        files += gfm.files
        gfm = nil
      rescue KadeployError => ke
        gfm.clean
        raise KadeployError.new(FetchFileError::INVALID_KEY,
          { :rid => ke.context[:rid], :status => 4}, ke.message)
      end
    end

    @reboot_info_hash_lock.synchronize {
      @reboot_info_hash[reboot_id][4] = files
    }

    gfm = nil

    clusters = exec_specific.node_set.group_by_cluster
    if clusters.size > 1
      clid = 1
    else
      clid = 0
    end

    clusters.each_key do |cluster|
      context[:cluster] = config.cluster_specific[cluster]
      if clusters.size > 1
        if context[:cluster].prefix.empty?
          context[:cluster].prefix = "c#{clid}"
          clid += 1
        end
      else
        context[:cluster].prefix = ''
      end
    end

    if clusters.size > 1
      tmp = ''
      clusters.each_key do |cluster|
        tmp += "  #{Debug.prefix(config.cluster_specific[cluster].prefix)}: #{config.cluster_specific[cluster].name}\n"
      end
      output.verbosel(0,"\nClusters involved in the reboot operation:\n#{tmp}\n",nil,false)
    end

    micros = []
    clusters.each_pair do |cluster, set|
      context[:cluster] = config.cluster_specific[cluster]
      threads << Thread.new do
        ret = KarebootAsyncError::NO_ERROR
        micro = CustomMicrostep.new(set, context)
        Thread.current[:micro] = micro
        micros << micro
        nodeset = Nodes::NodeSet.new
        set.linked_copy(nodeset)
        micro.debug(0,"Rebooting the nodes #{nodeset.to_s_fold}",nil)
        case exec_specific.reboot_kind
        when "env_recorded"
          #This should be the same case than a deployed env
          micro.switch_pxe("deploy_to_deployed_env")
        when "set_pxe"
          micro.switch_pxe("set_pxe", exec_specific.pxe_profile_msg)
        when "simple_reboot"
          #no need to change the PXE profile
        when "deploy_env"
          micro.switch_pxe("prod_to_deploy_env")
        else
          raise "Invalid kind of reboot: #{@reboot_kind}"
        end
        micro.reboot(exec_specific.reboot_level)
        micro.set_vlan unless exec_specific.vlan.nil?
        if exec_specific.wait then
          if (exec_specific.reboot_classical_timeout == nil) then
            timeout = @config.cluster_specific[cluster].timeout_reboot_classical
          else
            timeout = exec_specific.reboot_classical_timeout
          end
          if (exec_specific.reboot_kind == "deploy_env") then
            micro.wait_reboot("classical","deploy",true,timeout)
            if exec_specific.key and !exec_specific.key.empty?
              micro.send_key_in_deploy_env("tree")
            end
            nodeset.set_deployment_state("deploy_env", nil, db, exec_specific.true_user)
          else
            micro.wait_reboot(
              "classical",
              "user",
              true,
              timeout,
              [@config.common.ssh_port],
              []
            )
            ret = KarebootAsyncError::REBOOT_FAILED_ON_SOME_NODES if not micro.nodes_ko.empty?

            if (exec_specific.reboot_kind == "env_recorded") then
              if (exec_specific.deploy_part == @config.cluster_specific[cluster].prod_part) then
                micro.check_nodes("prod_env_booted")
                nodeset.set_deployment_state("prod_env", nil, db, exec_specific.true_user)
              else
                nodeset.set_deployment_state("recorded_env", nil, db, exec_specific.true_user)
              end
            end
          end
          if not micro.nodes_ok.empty? then
            global_nodes_mutex.synchronize {
              nodes_ok.add(micro.nodes_ok)
            }
          end
          if not micro.nodes_ko.empty? then
            global_nodes_mutex.synchronize {
              nodes_ko.add(micro.nodes_ko)
            }
          end
        end
        micro.debug(0,"Done rebooting the nodes #{nodeset.to_s_fold}",nil)
        ret
      end
    end

    if block_given?
      begin
        yield(reboot_id,threads)
      ensure
        @reboot_info_hash_lock.synchronize {
          # Unlock the cached files
          if @reboot_info_hash[reboot_id].size >= 4
            @reboot_info_hash[reboot_id][4].each do |file|
              file.release
            end
          end
          kareboot_delete_reboot_info(reboot_id)
        }
        # Clean cache
        @config.common.cache[:global].clean  if @config.common.cache[:global]
        @config.common.cache[:netboot].clean
        config = nil
      end
    else
      [reboot_id,threads]
    end
  end

  # Reboot a set of nodes from the client side in an synchronous way
  #
  # Arguments
  # * db: database handler
  # * client: DRb client handler
  # * exec_specific: instance of Config.exec_specific
  # Output
  # * return 0 in case of success, 1 if the reboot failed on some nodes, 2 if the reboot has not been launched, 3 if some pxe files cannot be grabbed, 4 if the ssh key file cannot be grabbed
  def run_kareboot_sync(db, client, exec_specific, drb_server)
    ret = 0
    disconnected = false
    if (exec_specific.verbose_level != nil) then
      vl = exec_specific.verbose_level
    else
      vl = @config.common.verbose_level
    end
    output = Debug::OutputControl.new(vl,
      exec_specific.debug, client, exec_specific.true_user, -1,
      @config.common.dbg_to_syslog, @config.common.dbg_to_syslog_level,
      @syslog_lock
    )

    begin
      run_kareboot(output, db, exec_specific, client) do |rid,microthreads|
        client.set_workflow_id(rid)
        # Client disconnection fallback
        micros = []
        microthreads.each do |microthread|
          micro = microthread[:micro]
          until micro
            sleep 0.2
            micro = microthread[:micro]
          end
          micros << micro
        end

        finished = false
        finthr = Thread.new do
          while (not finished) do
            begin
              client.test()
            rescue DRb::DRbConnError
              disconnected = true
              output.disable_client_output()
              output.verbosel(3, "Client disconnection")
              microthreads.each { |thread| thread.kill }
              micros.each do |micro|
                micro.output.disable_client_output()
                micro.debug(3,"Kill a reboot step")
                micro.kill
              end
              @reboot_info_hash_lock.synchronize {
                kareboot_delete_reboot_info(rid)
              }
              drb_server.stop_service()
              db.disconnect()
              finished = true
            end
            sleep(1)
          end
        end

        # Join threads
        microthreads.each { |thread| thread.join }
        micros.each do |micro|
          clname = micro.context[:cluster].name
          client.print("")
          if not micro.nodes_ok.empty? then
            client.print("Nodes correctly rebooted on cluster #{clname}")
            client.print(micro.nodes_ok.to_s(false, false, "\n"))
          end
          if not micro.nodes_ko.empty? then
            client.print("Nodes not correctly rebooted on cluster #{clname}")
            client.print(micro.nodes_ko.to_s(false, true, "\n"))
          end
          micro.free
        end
        micros = nil
        finished = true
        finthr.join

        if (not disconnected) then
          client.generate_files(@reboot_info_hash[rid][0],@reboot_info_hash[rid][1])
        end
      end
    rescue KadeployError => ke
      msg = KadeployError.to_msg(ke.errno)
      Debug::distant_client_error("#{msg} (error ##{ke.errno})",client) if msg and !msg.empty?
      client.print(ke.message) if ke.message and !ke.message.empty?
      #Debug::distant_client_error("Cannot run the reboot",client)
      @reboot_info_hash_lock.synchronize {
        # Unlock the cached files
        if @reboot_info_hash[ke.context[:rid]] and @reboot_info_hash[ke.context[:rid]].size >= 4
          @reboot_info_hash[ke.context[:rid]][4].each do |file|
            file.release
          end
        end
        kareboot_delete_reboot_info(ke.context[:rid])
      }
      # Clean cache
      @config.common.cache[:global].clean  if @config.common.cache[:global]
      @config.common.cache[:netboot].clean
      ret = (ke.context[:status].nil? ? -1 : ke.context[:status])
    end
    return ret
  end



  ##################################
  #        Kareboot Async          #
  ##################################

  # Reboot a set of nodes from the client side in an synchronous way
  #
  # Arguments
  # * db: database handler
  # * exec_specific: instance of Config.exec_specific
  # Output
  # * return a reboot id or nil if no reboot has been performed and an error code (0 in case of success, 1 if the reboot failed on some nodes, 2 if the reboot has not been launched, 3 if some pxe files cannot be grabbed)
  def run_kareboot_async(db, exec_specific)
    output = Debug::OutputControl.new(
      @config.common.verbose_level,
      exec_specific.debug, nil,
      exec_specific.true_user, -1,
      @config.common.dbg_to_syslog,
      @config.common.dbg_to_syslog_level, @syslog_lock
    )
    rid, microthreads = nil
    begin
      rid, microthreads = run_kareboot(output, db, exec_specific)
      Thread.new do
        microthreads.each { |thread| thread.join }
        @reboot_info_hash_lock.synchronize {
          @reboot_info_hash[rid][2] = true
        }
        if (@config.common.async_end_of_reboot_hook != "") then
          tmp = cmd = @config.common.async_end_of_reboot_hook.clone
          while (tmp.sub!("REBOOT_ID", reboot_id) != nil)  do
            cmd = tmp
          end
          system(cmd)
        end
        db.disconnect()
      end
    rescue KadeployError => ke
      microthreads.each do |microthread|
        microthread.kill
        microthread[:micro].output.disable_client_output()
        microthread[:micro].debug(3,"Kill a reboot step")
        microthread[:micro].kill
      end
      @reboot_info_hash_lock.synchronize {
        # Unlock the cached files
        if @reboot_info_hash[reboot_id].size >= 4
          @reboot_info_hash[reboot_id][4].each do |file|
            file.release
          end
        end
        kareboot_delete_reboot_info(ke.context[:rid])
      }
      # Clean cache
      @config.common.cache[:global].clean  if @config.common.cache[:global]
      @config.common.cache[:netboot].clean
      begin
        GC.start
      rescue TypeError
      end
      return nil, ke.errno
    end
    return rid, KarebootAsyncError::NO_ERROR
  end

  # Record reboot information
  #
  # Arguments
  # * reboot_id: reboot_id
  # * nodes_ok: nodes ok
  # * nodes_ko: nodes ko
  # * finished: array that contains a boolean to specify if the operation is finished
  # Output
  # * nothing
  def kareboot_add_reboot_info(reboot_id, nodes_ok, nodes_ko, finished)
    @reboot_info_hash[reboot_id] = [nodes_ok, nodes_ko, finished]
  end

  # Delete reboot information
  #
  # Arguments
  # * reboot_id: reboot id
  # Output
  # * nothing
  def kareboot_delete_reboot_info(reboot_id)
    @reboot_info_hash.delete(reboot_id)
  end


  ##################################
  #             Kastat             #
  ##################################
  
  # Run a Kastat command
  #
  # Arguments
  # * db: database handler
  # * client: DRb handler of the Kadeploy client
  # * exec_specific: instance of Config.exec_specific
  # Output
  # * return true if everything is ok, false otherwise
  def run_kastat(db, client, exec_specific, drb_server)
    begin
      finished = false
      res = nil
      tid = Thread.new {
        case exec_specific.operation
        when "print_workflow"
          res = kastat_print_workflow(exec_specific, client, db)
        when "list_all"
          res = kastat_list_all(exec_specific, client, db)
        when "list_last"
          res = kastat_list_last(exec_specific, client, db)
        when "list_retries"
          res = kastat_list_retries(exec_specific, client, db)
        when "list_failure_rate"
          res = kastat_list_failure_rate(exec_specific, client, db)
        when "list_min_failure_rate"
          res = kastat_list_failure_rate(exec_specific, client, db)
        else
        end
      }
      finthr = Thread.new {
        while (not finished) do
          begin
            client.test()
          rescue DRb::DRbConnError
            Thread.kill(tid)
            drb_server.stop_service()
            db.disconnect()
            finished = true
          end
            sleep(1)
        end
      }
      tid.join
      finished = true
      finthr.join
    rescue KadeployError => ke
      msg = KadeployError.to_msg(ke.errno)
      Debug::distant_client_error("#{msg} (error ##{ke.errno})",client) if msg and !msg.empty?
      client.print(ke.message) if ke.message and !ke.message.empty?
      finished = true
      finthr.join
    end
    return res
  end


  def generic_where_nodelist(exec_specific, field)
    args = []
    ret = ''

    unless exec_specific.node_list.empty? then
      nbnodes = 0
      exec_specific.node_list.each { |node|
        if Nodes::REGEXP_NODELIST =~ node then
          nodes = Nodes::NodeSet::nodes_list_expand("#{node}")
        else
          nodes = [node]
        end

        nodes.each{ |n|
          if (node != "*") then
            args << n
            nbnodes += 1
          end
        }
      }
      ret += "(#{(["#{field} = ?"] * nbnodes).join(" OR ")})"
    end

    return [args,ret]
  end

  # Generate some filters for the output according the options
  #
  # Arguments
  # * exec_specific: instance of Config.exec_specific
  # Output
  # * return a string that contains the where clause corresponding to the filters required
  def kastat_generic_where_clause(exec_specific)
    args, ret = generic_where_nodelist(exec_specific,'hostname')

    if (exec_specific.date_min != 0) then
      ret += ' AND ' unless ret.empty?
      args << exec_specific.date_min
      ret += "start >= ?"
    end

    if (exec_specific.date_max != 0) then
      ret += ' AND ' unless ret.empty?
      args << exec_specific.date_max
      ret += "start <= ?"
    end

    return [args, ret]
  end

  def db_generate_fields(base_fields, exec_fields, default_fields)
    fields = nil
    if exec_fields.empty?
      fields = default_fields
    else
      fields = exec_fields
    end
    fields.collect{|f| base_fields.index(f) }
  end

  def db_print_results(results,fields)
    i = 0
    buff = ""
    results.each_array do |row|
      fields.each do |j|
        if row[j].is_a?(String)
          row[j].gsub!(/\n/, "\\n")
          row[j].gsub!(/\r/, "\\r")
          buff.concat(row[j])
          buff.concat(",")
        else
          buff.concat(row[j].to_s)
          buff.concat(",")
        end
      end
      buff.chop!
      buff.concat("\n")
      i+=1
      if (i%RESULTS_PRINT_PITCH == 0)
        yield(buff)
        buff = ""
      end
    end
    yield(buff) unless buff.empty?
    buff = nil
    GC.start
  end

  # List the information about the nodes that require a given number of retries to be deployed
  #
  # Arguments
  # * exec_specific: instance of Config.exec_specific
  # * client: DRb handler of the Kadeploy client
  # * db: database handler
  # Output
  # * print the filtred information about the nodes that require a given number of retries to be deployed
  def kastat_list_retries(exec_specific, client, db)
    tmpargs, generic_where_clause = kastat_generic_where_clause(exec_specific)
    step_list = String.new

    args = []
    if (not exec_specific.steps.empty?) then
      steps = []
      exec_specific.steps.each { |step|
        case step
        when "1"
          steps.push("retry_step1 >= ?")
          args << exec_specific.min_retries
        when "2"
          steps.push("retry_step2 >= ?")
          args << exec_specific.min_retries
        when "3"
          steps.push("retry_step3 >= ?")
          args << exec_specific.min_retries
        end
      }
      step_list = "(#{steps.join(" AND ")})"
    else
      step_list = "(retry_step1 >= ? OR retry_step2 >= ? OR retry_step3 >= ?)"
      3.times{ args << exec_specific.min_retries }
    end
    args += tmpargs

    query = "SELECT COUNT(*) FROM log WHERE #{step_list}"
    query += " AND #{generic_where_clause}" unless generic_where_clause.empty?
    res = db.run_query(query,*args)

    if res.to_array[0][0] == 0
      Debug::distant_client_print("No information is available", client)
      return false
    end

    (res.to_array[0][0]*1.0/RESULTS_MAX_PER_REQUEST).ceil.times do |i|
      query = "SELECT * FROM log WHERE #{step_list}"
      query += " AND #{generic_where_clause}" unless generic_where_clause.empty?
      query += " LIMIT #{i*RESULTS_MAX_PER_REQUEST},#{RESULTS_MAX_PER_REQUEST}"

      res = db.run_query(query,*args)

      fields = db_generate_fields(res.fields,exec_specific.fields,
        ["start","hostname","retry_step1","retry_step2","retry_step3"]
      )
      db_print_results(res,fields) do |str|
        Debug::distant_client_print(str,client)
      end

      res = nil
      GC.start
    end
    true
  end

  # List the information about the nodes that have at least a given failure rate
  #
  # Arguments
  # * exec_specific: instance of Config.exec_specific
  # * client: DRb handler of the Kadeploy client
  # * db: database handler
  # Output
  # * print the filtred information about the nodes that have at least a given failure rate
  def kastat_list_failure_rate(exec_specific, client, db)
    args, generic_where_clause = kastat_generic_where_clause(exec_specific)

    query = "SELECT hostname,COUNT(*) FROM log"
    query += " WHERE #{generic_where_clause}" unless generic_where_clause.empty?
    query += " GROUP BY hostname"

    res = db.run_query(query,*args)
    unless res.num_rows > 0
      Debug::distant_client_print("No information is available", client)
      return
    end

    total = {}
    res.to_array.each do |row|
      total[row[0]] = row[1]
    end

    query = "SELECT hostname,COUNT(*) FROM log"
    query += " WHERE success = ?"
    query += " AND #{generic_where_clause}" unless generic_where_clause.empty?
    query += " GROUP BY hostname"
    args = ['true'] + args
    res = db.run_query(query,*args)

    success = {}
    total.keys.each do |node|
      success[node] = 0
    end
    res.to_array.each do |row|
      success[row[0]] = row[1]
    end

    total.each_pair do |node,tot|
      rate = 100 - (100 * success[node].to_f / tot)
      if (exec_specific.min_rate == nil) or (rate >= exec_specific.min_rate)
        Debug::distant_client_print("#{node}: #{'%.2f'%rate}%", client)
      end
    end
    res = nil
    GC.start
    true
  end

  # List the information about all the nodes
  #
  # Arguments
  # * exec_specific: instance of Config.exec_specific
  # * client: DRb handler of the Kadeploy client
  # * db: database handler
  # Output
  # * print the information about all the nodes
  def kastat_list_all(exec_specific, client, db)
    args, generic_where_clause = kastat_generic_where_clause(exec_specific)

    query = "SELECT COUNT(*) FROM log"
    query += " WHERE #{generic_where_clause}" unless generic_where_clause.empty?
    res = db.run_query(query,*args)

    if res.to_array[0][0] == 0
      Debug::distant_client_print("No information is available", client)
      return false
    end

    (res.to_array[0][0]*1.0/RESULTS_MAX_PER_REQUEST).ceil.times do |i|
      query = "SELECT * FROM log"
      query += " WHERE #{generic_where_clause}" unless generic_where_clause.empty?
      query += " LIMIT #{i*RESULTS_MAX_PER_REQUEST},#{RESULTS_MAX_PER_REQUEST}"

      res = db.run_query(query,*args)

      fields = db_generate_fields(res.fields,exec_specific.fields,
        [
          "user","hostname","step1","step2","step3",
          "timeout_step1","timeout_step2","timeout_step3",
          "retry_step1","retry_step2","retry_step3",
          "start",
          "step1_duration","step2_duration","step3_duration",
          "env","anonymous_env","md5",
          "success","error"
        ]
      )
      db_print_results(res,fields) do |str|
        Debug::distant_client_print(str,client)
      end

      res = nil
      GC.start
    end
    true
  end

  def kastat_print_workflow(exec_specific, client, db)
    tmpargs, generic_where_clause = generic_where_nodelist(exec_specific,'hostname')
    query = "SELECT * FROM log WHERE deploy_id = ?"
    args = [ exec_specific.workflow_id ]
    query += " AND #{generic_where_clause}" unless generic_where_clause.empty?
    args += tmpargs

    res = db.run_query(query,*args)

    if res.num_rows == 0
      Debug::distant_client_print("No information is available", client)
      return false
    end

    fields = db_generate_fields(res.fields,exec_specific.fields,
      [
        "user","hostname","step1","step2","step3",
        "timeout_step1","timeout_step2","timeout_step3",
        "retry_step1","retry_step2","retry_step3",
        "start",
        "step1_duration","step2_duration","step3_duration",
        "env","anonymous_env","md5",
        "success","error"
      ]
    )
    db_print_results(res,fields) do |str|
      Debug::distant_client_print(str,client)
    end

    res = nil
    GC.start
    true
  end

  def kastat_list_last(exec_specific, client, db)
    args, generic_where_clause = generic_where_nodelist(exec_specific,'l1.hostname')
    query = "SELECT * FROM log l1 INNER JOIN ("\
      " SELECT hostname,MAX(start) as maxstart FROM log GROUP BY hostname"\
    ") l2 ON l1.hostname = l2.hostname AND l1.start = l2.maxstart"
    query += " WHERE #{generic_where_clause}" unless generic_where_clause.empty?
    query += " GROUP BY l1.hostname;"

    res = db.run_query(query,*args)

    if res.num_rows == 0
      Debug::distant_client_print("No information is available", client)
      return false
    end

    fields = db_generate_fields(res.fields,exec_specific.fields,
      [
        "user","hostname","step1","step2","step3",
        "timeout_step1","timeout_step2","timeout_step3",
        "retry_step1","retry_step2","retry_step3",
        "start",
        "step1_duration","step2_duration","step3_duration",
        "env","anonymous_env","md5",
        "success","error"
      ]
    )
    db_print_results(res,fields) do |str|
      Debug::distant_client_print(str,client)
    end

    res = nil
    GC.start
    true
  end





  ##################################
  #            Kanodes             #
  ##################################

  # Run a Kanodes command
  #
  # Arguments
  # * db: database handler
  # * client: DRb handler of the Kadeploy client
  # * exec_specific: instance of Config.exec_specific
  # Output
  # * return true if everything is ok, false otherwise
  def run_kanodes(db, client, exec_specific, drb_server)
    begin
      finished = false
      res = nil
      tid = Thread.new {
        case exec_specific.operation
        when "get_deploy_state"
          res = kanodes_get_deploy_state(exec_specific, client, db)
        when "get_yaml_dump"
          res = kanodes_get_yaml_dump(exec_specific, client)
        end
      }
      finthr = Thread.new {
        while (not finished) do
          begin
            client.test()
          rescue DRb::DRbConnError
            Thread.kill(tid)
            drb_server.stop_service()
            db.disconnect()
            finished = true
          end
            sleep(1)
        end
      }
      tid.join
      finished = true
      finthr.join
    rescue KadeployError => ke
      msg = KadeployError.to_msg(ke.errno)
      Debug::distant_client_error("#{msg} (error ##{ke.errno})",client) if msg and !msg.empty?
      client.print(ke.message) if ke.message and !ke.message.empty?
      finished = true
      finthr.join
    end
    return res
  end
  
  # List the deploy information about the nodes
  #
  # Arguments
  # * exec_specific: instance of Config.exec_specific
  # * client: DRb handler of the Kadeploy client
  # * db: database handler
  # Output
  # * prints the information about the nodes in a CSV format
  def kanodes_get_deploy_state(exec_specific, client, db)
    args, where_nodelist = generic_where_nodelist(exec_specific,'nodes.hostname')

    query = "SELECT nodes.hostname, nodes.state, nodes.user, environments.name, environments.version, environments.user \
     FROM nodes \
     LEFT JOIN environments ON nodes.env_id = environments.id"
    #If no node list is given, we print everything
    query += " WHERE #{where_nodelist}" unless where_nodelist.empty?
    query += " ORDER BY nodes.hostname"

    res = db.run_query(query,*args)
    if (res.num_rows > 0)
      fields = db_generate_fields(res.fields,[],res.fields)
      db_print_results(res,fields) do |str|
        Debug::distant_client_print(str,client)
      end
    else
      Debug::distant_client_print("No information concerning these nodes", client)
      return(1)
    end
    return(0)
  end

  # Get a YAML output of the current deployments
  #
  # Arguments
  # * exec_specific: instance of Config.exec_specific
  # * client: DRb handler of the Kadeploy client
  # Output
  # * prints the YAML output of the current deployments
  def kanodes_get_yaml_dump(exec_specific, client)
    Debug::distant_client_print(kanodes_get_workflow_state(exec_specific.wid), client)
    return(0)
  end

  # Get a YAML output of the workflows (RPC)
  #
  # Arguments
  # * workflow_id (opt): workflow id
  # Output
  # * return a string containing the YAML output
  def kanodes_get_workflow_state(workflow_id = "")
    str = String.new
    @workflow_info_hash_lock.lock
    if (@workflow_info_hash.has_key?(workflow_id)) then
      hash = Hash.new

      states = nil
      @workflow_info_hash[workflow_id][:workflows].each do |workflow|
        state = workflow.state
        if states.nil?
          states = state
        else
          states['nodes'].merge!(state['nodes'])
        end
      end
      hash[workflow_id] = states

      str = hash.to_yaml
      hash = nil
    elsif (workflow_id == "") then
      hash = Hash.new
      @workflow_info_hash.each_pair { |key,workflow_info_hash|
        states = nil
        workflow_info_hash[:workflows].each do |workflow|
          state = workflow.state
          if states.nil?
            states = state
          else
            states['nodes'].merge!(state['nodes'])
          end
        end
        hash[key] = states
      }
      str = hash.to_yaml
      hash = nil
    end
    @workflow_info_hash_lock.unlock
    return str
  end






  ##################################
  #            Karights            #
  ##################################

  # Run a Karights command
  #
  # Arguments
  # * db: database handler
  # * client: DRb handler of the Kadeploy client
  # * exec_specific: instance of Config.exec_specific
  # Output
  # * return true if everything is ok, false otherwise
  def run_karights(db, client, exec_specific, drb_server)
    begin
      finished = false
      res = nil
      tid = Thread.new {
        case exec_specific.operation  
        when "add"
          res = karights_add_rights(exec_specific, client, db)
        when "delete"
          res = karights_delete_rights(exec_specific, client, db)
        when "show"
          res = karights_show_rights(exec_specific, client, db)
        end
      }
      finthr = Thread.new {
        while (not finished) do
          begin
            client.test()
          rescue DRb::DRbConnError
            Thread.kill(tid)
            drb_server.stop_service()
            db.disconnect()
            finished = true
          end
          sleep(1)
        end
      }
      tid.join
      finished = true
      finthr.join
    rescue KadeployError => ke
      msg = KadeployError.to_msg(ke.errno)
      Debug::distant_client_error("#{msg} (error ##{ke.errno})",client) if msg and !msg.empty?
      client.print(ke.message) if ke.message and !ke.message.empty?
      finished = true
      finthr.join
    end
    return res
  end

  # Show the rights of a user defined in exec_specific.user
  #
  # Arguments
  # * exec_specific: instance of Config.exec_specific
  # * client: DRb handler of the Kadeploy client
  # * db: database handler
  # Output
  # * print the rights of a specific user
  # * return true if some rights are granted for the given user, false otherwise
  def karights_show_rights(exec_specific, client, db)
    hash = Hash.new
    res = db.run_query("SELECT * FROM rights WHERE user = ?",exec_specific.user)
    if res != nil then
      res.each_hash { |row|
        if (not hash.has_key?(row["node"])) then
          hash[row["node"]] = Array.new
        end
        hash[row["node"]].push(row["part"])
      }
      if (res.num_rows > 0) then
        Debug::distant_client_print("The user #{exec_specific.user} has the deployment rights on the following nodes:", client)
        hash.each_pair { |node, part_list|
          Debug::distant_client_print("### #{node}:#{part_list.join(", ")}", client)
        }
      else
        Debug::distant_client_print("No rights have been given for the user #{exec_specific.user}", client)
        return false
      end
    end
    return true
  end

  # Add some rights on the nodes defined in exec_specific.node_list
  # and on the parts defined in exec_specific.part_list to a specific
  # user defined in exec_specific.user
  #
  # Arguments
  # * exec_specific: instance of Config.exec_specific
  # * client: DRb handler of the Kadeploy client
  # * db: database handler
  # Output
  # * return true if all the expected rights have been added, false otherwise
  def karights_add_rights(exec_specific, client, db)
    #check if other users have rights on some nodes
    res = true
    nodes_to_remove = Array.new
    args, where_nodelist = generic_where_nodelist(exec_specific,'node')

    if not args.empty? then
      query = "SELECT DISTINCT node FROM rights WHERE part<>\"*\""
      query += " AND #{where_nodelist}" unless where_nodelist.empty?
      res = db.run_query(query,*args)
      res.each_hash { |row|
        nodes_to_remove.push(row["node"])
      }
    end
    if ((not nodes_to_remove.empty?) && exec_specific.overwrite_existing_rights) then
      nodelist = ([ "node = ?" ] * nodes_to_remove.size).join(" OR ")
      query = "DELETE FROM rights WHERE part<>\"*\" AND (#{nodelist})"
      args = nodes_to_remove.dup
      db.run_query(query,*args)
      Debug::distant_client_print("Some rights have been removed on the nodes #{nodes_to_remove.join(", ")}", client)
      nodes_to_remove.clear
    end

    args = []
    values_to_insert = 0
    exec_specific.node_list.each { |node|
      exec_specific.part_list.each { |part|
        if Nodes::REGEXP_NODELIST =~ node
          nodes = Nodes::NodeSet::nodes_list_expand("#{node}")
        else
          nodes = [node]
        end
        nodes.each{ |n|
          if (not nodes_to_remove.include?(n)) then
            if ((node == "*") || (part == "*")) then
              #check if the rights are already inserted
              res = db.run_query(
                "SELECT * FROM rights WHERE user = ? AND node = ? AND part = ?",
                exec_specific.user, n, part
              )
              if (res.num_rows == 0)
                values_to_insert += 1
                args << exec_specific.user
                args << n
                args << part
              end
            else
              values_to_insert += 1
              args << exec_specific.user
              args << n
              args << part
            end
          else
            Debug::distant_client_print("The node #{n} has been removed from the rights assignation since another user has some rights on it", client)
            res = false
          end
        }
      }
    }
    #add the rights
    if values_to_insert > 0 then
      values = ([ "(?, ?, ?)" ] * values_to_insert).join(", ")
      query = "INSERT INTO rights (user, node, part) VALUES #{values}"
      db.run_query(query,*args)
    else
      Debug::distant_client_print("No rights added", client)
      res = false
    end
    return res
  end

  # Remove some rights on the nodes defined in exec_specific.node_list
  # and on the parts defined in exec_specific.part_list to a specific
  # user defined in exec_specific.user
  #
  # Arguments
  # * exec_specific: instance of Config.exec_specific
  # * client: DRb handler of the Kadeploy client
  # * db: database handler
  # Output
  # * return true if all the expected rights have been removed, false otherwise
  def karights_delete_rights(exec_specific, client, db)
    res = true
    exec_specific.node_list.each { |node|
      exec_specific.part_list.each { |part|
        if Nodes::REGEXP_NODELIST =~ node then
          nodes = Nodes::NodeSet::nodes_list_expand("#{node}")
        else
          nodes = [node]
        end
        nodes.each{ |n|
          res = db.run_query(
            "DELETE FROM rights WHERE user = ? AND node = ? AND part = ?",
            exec_specific.user, n, part
          )
          if (res.affected_rows == 0)
            Debug::distant_client_print("No rights have been removed for the node #{n} on the partition #{part}", client)
            res = false
          end
        }
      }
    }
    return res
  end



  ##################################
  #             Kaenv              #
  ##################################

  # Run a Kaenv command
  #
  # Arguments
  # * db: database handler
  # * client: DRb handler of the Kadeploy client
  # * exec_specific: instance of Config.exec_specific
  # Output
  # * return true if everything is ok, false otherwise
  def run_kaenv(db, client, exec_specific, drb_server)
    begin
      finished = false
      ret = nil
      tid = Thread.new {
        case exec_specific.operation
        when "list"
          ret = kaenv_list_environments(exec_specific, client, db)
        when "add"
          ret = kaenv_add_environment(exec_specific, client, db)
        when "delete"
          ret = kaenv_delete_environment(exec_specific, client, db)
        when "print"
          ret = kaenv_print_environment(exec_specific, client, db)
        when "update-tarball-md5"
          ret = kaenv_update_tarball_md5(exec_specific, client, db)
        when "update-preinstall-md5"
          ret = kaenv_update_preinstall_md5(exec_specific, client, db)
        when "update-postinstalls-md5"
          ret = kaenv_update_postinstall_md5(exec_specific, client, db)
        when "remove-demolishing-tag"
          ret = kaenv_remove_demolishing_tag(exec_specific, client, db)
        when "set-visibility-tag"
          ret = kaenv_set_visibility_tag(exec_specific, client, db)
        when "move-files"
          ret = kaenv_move_files(exec_specific, client, db)
        when "migrate"
          ret = kaenv_migrate_environment(exec_specific, client, db)
        end
      }
      finthr = Thread.new {
        while (not finished) do
          begin
            client.test()
          rescue DRb::DRbConnError
            Thread.kill(tid)
            drb_server.stop_service()
            db.disconnect()
            finished = true
          end
          sleep(1)
        end
      }
      tid.join
      finished = true
      finthr.join
    rescue KadeployError => ke
      msg = KadeployError.to_msg(ke.errno)
      Debug::distant_client_error("#{msg} (error ##{ke.errno})",client) if msg and !msg.empty?
      client.print(ke.message) if ke.message and !ke.message.empty?
      finished = true
      finthr.join
    end
    return ret
  end

  def kaenv_migrate_environment(exec_specific, client, db)
    if (env = exec_specific.environment)
      env.full_view(client)
      return 0
    else
      return 1
    end
  end

  # List the environments of a user defined in exec_specific.user
  #
  # Arguments
  # * exec_specific: instance of Config.exec_specific
  # * client: DRb handler of the Kadeploy client
  # * db: database handler
  # Output
  # * print the environments of a given user
  def kaenv_list_environments(exec_specific, client, db)
    env = EnvironmentManagement::Environment.new
    user = exec_specific.user ? exec_specific.user : exec_specific.true_user
    args = []
    where = ''
    if (user == "*") then #we show the environments of all the users
      if (exec_specific.show_all_version == false) then
        if exec_specific.version then
          where = "version = ? \
                   AND visibility <> 'private' \
                   GROUP BY name"
          args << exec_specific.version
        else
          where = "e1.visibility <> 'private' \
                   AND e1.version=( \
                     SELECT MAX(e2.version) FROM environments e2 \
                     WHERE e2.name = e1.name \
                     AND e2.user = e1.user \
                     AND e2.visibility <> 'private' \
                     GROUP BY e2.user, e2.name)"
        end
      else
        query = "visibility <> 'private'"
      end
    else
      #If the user wants to print the environments of another user, private environments are not shown
      mask_private_env = exec_specific.true_user != user
      if (exec_specific.show_all_version == false) then
        if exec_specific.version then
          if mask_private_env then
            where = "user = ? \
                     AND version = ? \
                     AND visibility <> 'private'"
            args << user
            args << exec_specific.version
          else
            where = "(user = ? AND version = ?) \
                     OR (user <> ? AND version = ? AND visibility = 'public')"
            2.times do
              args << user
              args << exec_specific.version
            end
          end
        else
          if mask_private_env then
            where = "e1.user = ? \
                     AND e1.visibility <> 'private' \
                     AND e1.version = ( \
                       SELECT MAX(e2.version) FROM environments e2 \
                       WHERE e2.name = e1.name \
                       AND e2.user = e1.user \
                       AND e2.visibility <> 'private' \
                       GROUP BY e2.user, e2.name)"
            args << user
          else
            where = "(e1.user = ? \
                       OR (e1.user <> ? AND e1.visibility = 'public')) \
                     AND e1.version = ( \
                       SELECT MAX(e2.version) FROM environments e2 \
                       WHERE e2.name = e1.name \
                       AND e2.user = e1.user \
                       AND (e2.user = ? \
                       OR (e2.user <> ? AND e2.visibility = 'public')) \
                       GROUP BY e2.user,e2.name)"
            4.times{ args << user }
          end
        end
      else
        if mask_private_env then
          where = "user = ? AND visibility <> 'private'"
          args << user
        else
          where = "user = ? OR (user <> ? AND visibility = 'public')"
          2.times{ args << user }
        end
      end
    end

    query = "SELECT * FROM environments e1"
    query += " WHERE #{where}" unless where.empty?
    query += " ORDER BY e1.user, e1.name, e1.version"
    res = db.run_query(query,*args)

    if (res.num_rows > 0) then
      env.short_view_header(client)
      res.each_hash { |row|
        env.load_from_dbhash(row)
        env.short_view(client)
      }
    else
      Debug::distant_client_print("No environment has been found", client)
    end
  end

  # Add an environment described in the file exec_specific.file
  #
  # Arguments
  # * exec_specific: instance of Config.exec_specific
  # * client: DRb handler of the Kadeploy client
  # * db: database handler
  # Output
  # * nothing
  def kaenv_add_environment(exec_specific, client, db)
    if (env = exec_specific.environment)
      if (envs = exec_specific.environment.save_to_db(db)) == true
        Debug::distant_client_print(
          "The environment #{env.name} version #{env.version} of #{env.user} "\
          "has been added",
          client
        )
        return 0
      else
        if envs and !envs.empty?
          env = envs[0]
          if env.visibility == 'public'
            Debug::distant_client_print(
              "A public environment with the name #{env.name} "\
              "and the version #{env.version} has already been recorded",
              client
            )
          else
            Debug::distant_client_print(
              "An environment with the name #{env.name} "\
              "and the version #{env.version} has already been recorded "\
              "for the user #{env.user}",
              client
            )
          end
        else
          Debug::distant_client_print("Environment cannot be add",client)
        end
        return 1
      end
    end
  end

  # Delete the environment specified in exec_specific.env_name
  #
  # Arguments
  # * exec_specific: instance of Config.exec_specific
  # * client: DRb handler of the Kadeploy client
  # * db: database handler
  # Output
  # * nothing
  def kaenv_delete_environment(exec_specific, client, db)
    # almighty users can delete environments of other users
    user = nil
    if exec_specific.user \
    and @config.common.almighty_env_users.include?(exec_specific.true_user)
      user = exec_specific.user
    else
      user = exec_specific.true_user
    end

    ret = EnvironmentManagement::Environment.del_from_db(
      db,
      exec_specific.env_name,
      exec_specific.version,
      user,
      true
    )

    if ret
      Debug::distant_client_print(
        "The environment #{ret.name} version #{ret.version} of #{ret.user} "\
        "has been deleted",
        client
      )
      return 0
    else
      Debug::distant_client_print("No environment has been deleted", client)
      return 1
    end
  end

  # Print the environment designed by exec_specific.env_name and that belongs to the user specified in exec_specific.user
  #
  # Arguments
  # * exec_specific: instance of Config.exec_specific
  # * client: DRb handler of the Kadeploy client
  # * db: database handler
  # Output
  # * print the specified environment that belongs to the specified user
  def kaenv_print_environment(exec_specific, client, db)
    version = (exec_specific.show_all_version ? true : exec_specific.version)
    user = exec_specific.user || exec_specific.true_user
    private_envs = exec_specific.user.nil? \
      || exec_specific.user == exec_specific.true_user

    envs = EnvironmentManagement::Environment.get_from_db(
      db,
      exec_specific.env_name,
      version,
      user,
      private_envs,
      exec_specific.user.nil?
    )

    if envs and !envs.empty?
      envs.each do |env|
        env.full_view(client)
      end
      return 0
    else
      Debug::distant_client_error(
        "The environment #{exec_specific.env_name} cannot be loaded. "\
        "Maybe the version number does not exist "\
        "or it belongs to another user",
        client
      )
      return 1
    end
  end


  def _update_file_md5(exec_specific, client, db, type)
    # almighty users can delete environments of other users
    user = nil
    if exec_specific.user \
    and @config.common.almighty_env_users.include?(exec_specific.true_user)
      user = exec_specific.user
    else
      user = exec_specific.true_user
    end

    envs = EnvironmentManagement::Environment.get_from_db(
      db,
      exec_specific.env_name,
      exec_specific.version,
      user,
      true,
      false
    )

    env = nil
    if envs and !envs.empty?
      env = envs[0]
    else
      Debug::distant_client_error(
        "The environment #{exec_specific.env_name} cannot be loaded. "\
        "Maybe the version number does not exist "\
        "or it belongs to another user",
        client
      )
      return 1
    end

    value = yield(env)

    if value.nil?
      Debug::distant_client_print("No environment has been updated", client)
      return 1
    end

    ret = EnvironmentManagement::Environment.update_to_db(
      db,
      exec_specific.env_name,
      exec_specific.version,
      user,
      true,
      {type => value},
      env
    )

    if ret
      Debug::distant_client_print(
        "The environment #{env.name} version #{env.version} of #{env.user} "\
        "has been updated",
        client
      )
      return 0
    else
      Debug::distant_client_print("No environment has been updated", client)
      return 1
    end
  end

  # Update the md5sum of the tarball
  #
  # * exec_specific: instance of Config.exec_specific
  # * client: DRb handler of the Kadeploy client
  # * db: database handler
  # Output
  # * nothing
  def kaenv_update_tarball_md5(exec_specific, client, db)
    _update_file_md5(exec_specific, client, db, 'tarball') do |env|
      ret = nil
      if env.tarball
        tar = env.tarball.dup
        md5 = nil
        begin
          md5 = Managers::Fetch[tar['file'],FetchFileError::INVALID_ENVIRONMENT_TARBALL,client].checksum
        rescue KadeployError => ke
          msg = KadeployError.to_msg(ke.errno)
          Debug::distant_client_error("#{msg} (error ##{ke.errno})",client) \
            if msg and !msg.empty?
          client.print(ke.message) if ke.message and !ke.message.empty?
          return nil
        end

        if tar['md5'] == 0 or !md5 or md5.empty?
          Debug::distant_client_error(
            "The md5 of the file #{tar['file']} cannot be obtained",
            client
          )
          ret = nil
        elsif tar['md5'] and tar['md5'] == md5
          client.print("The md5 of the file #{tar['file']} already is up to date")
          ret = nil
        else
          client.print("The md5 of the file #{tar['file']} will be updated")
          tar['md5'] = md5
          ret = EnvironmentManagement::Environment.flatten_image(tar,true)
        end
      else
        Debug::distant_client_print("No image to update", client)
        ret = nil
      end
      ret
    end
  end

  # Update the md5sum of the preinstall
  #
  # * exec_specific: instance of Config.exec_specific
  # * client: DRb handler of the Kadeploy client
  # * db: database handler
  # Output
  # * nothing
  def kaenv_update_preinstall_md5(exec_specific, client, db)
    _update_file_md5(exec_specific, client, db, 'preinstall') do |env|
      ret = nil
      if env.preinstall
        pre = env.preinstall.dup
        md5 = nil
        begin
          md5 = Managers::Fetch[pre['file'],FetchFileError::INVALID_PREINSTALL,client].checksum
        rescue KadeployError => ke
          msg = KadeployError.to_msg(ke.errno)
          Debug::distant_client_error("#{msg} (error ##{ke.errno})",client) \
            if msg and !msg.empty?
          client.print(ke.message) if ke.message and !ke.message.empty?
          return nil
        end

        if pre['md5'] == 0 or !md5 or md5.empty?
          Debug::distant_client_error(
            "The md5 of the file #{pre['file']} cannot be obtained",
            client
          )
          ret = nil
        elsif pre['md5'] and pre['md5'] == md5
          client.print("The md5 of the file #{pre['file']} already is up to date")
          ret = nil
        else
          client.print("The md5 of the file #{pre['file']} will be updated")
          pre['md5'] = md5
          ret = EnvironmentManagement::Environment.flatten_preinstall(pre,true)
        end
      else
        Debug::distant_client_print("No preinstall to update", client)
        ret = nil
      end
      ret
    end
  end

  # Update the md5sum of the postinstall files
  #
  # * exec_specific: instance of Config.exec_specific
  # * client: DRb handler of the Kadeploy client
    # * db: database handler
  # Output
  # * nothing
  def kaenv_update_postinstall_md5(exec_specific, client, db)
    _update_file_md5(exec_specific, client, db, 'postinstall') do |env|
      ret = nil
      if env.postinstall and !env.postinstall.empty?
        posts = env.postinstall.dup
        posts.each do |post|
          md5 = nil
          begin
            md5 = Managers::Fetch[post['file'],FetchFileError::INVALID_POSTINSTALL,client].checksum
          rescue KadeployError => ke
            msg = KadeployError.to_msg(ke.errno)
            Debug::distant_client_error("#{msg} (error ##{ke.errno})",client) \
              if msg and !msg.empty?
            client.print(ke.message) if ke.message and !ke.message.empty?
            return nil
          end

          if md5 == 0 or !md5 or md5.empty?
            Debug::distant_client_error(
              "The md5 of the file #{post['file']} cannot be obtained",
              client
            )
            ret = nil
            break
          elsif post['md5'] and post['md5'] == md5
            client.print("The md5 of the file #{post['file']} already is up to date")
          else
            client.print("The md5 of the file #{post['file']} will be updated")
            post['md5'] = md5
            ret = true
          end
        end
        ret = EnvironmentManagement::Environment.flatten_postinstall(posts,true) if ret
      else
        Debug::distant_client_print("No postinstall to update", client)
        ret = nil
      end
      ret
    end
  end

  # Remove the demolishing tag on an environment
  #
  # Arguments
  # * exec_specific: instance of Config.exec_specific
  # * client: DRb handler of the Kadeploy client
  # * db: database handler
  # Output
  # * nothing
  def kaenv_remove_demolishing_tag(exec_specific, client, db)
    # almighty users can delete environments of other users
    user = nil
    if exec_specific.user \
    and @config.common.almighty_env_users.include?(exec_specific.true_user)
      user = exec_specific.user
    else
      user = exec_specific.true_user
    end

    ret = EnvironmentManagement::Environment.update_to_db(
      db,
      exec_specific.env_name,
      exec_specific.version,
      user,
      true,
      {'demolishing_env' => 0}
    )

    if ret
      Debug::distant_client_print(
        "The environment #{ret.name} version #{ret.version} of #{ret.user} "\
        "has been updated",
        client
      )
      return 0
    else
      Debug::distant_client_print("No environment has been updated", client)
      return 1
    end
  end

  # Modify the visibility tag of an environment
  #
  # Arguments
  # * exec_specific: instance of Config.exec_specific
  # * client: DRb handler of the Kadeploy client
  # * db: database handler
  # Output
  # * nothing
  def kaenv_set_visibility_tag(exec_specific, client, db)
    # almighty users can delete environments of other users
    user = nil

    if @config.common.almighty_env_users.include?(exec_specific.true_user)
      if exec_specific.user \
        user = exec_specific.user
      else
        user = exec_specific.true_user
      end
    else
      if exec_specific.visibility_tag == "public"
        Debug::distant_client_print(
          'Only the environment administrators can set the "public" tag',
          client
        )
        return 1
      else
        user = exec_specific.true_user
      end
    end

    ret = EnvironmentManagement::Environment.update_to_db(
      db,
      exec_specific.env_name,
      exec_specific.version,
      user,
      true,
      {'visibility' => exec_specific.visibility_tag}
    )

    if ret
      Debug::distant_client_print(
        "The environment #{ret.name} version #{ret.version} of #{ret.user} "\
        "has been updated",
        client
      )
      return 0
    else
      Debug::distant_client_print("No environment has been updated", client)
      return 1
    end
  end

  # Move some file locations in the environment table
  #
  # Arguments
  # * exec_specific: instance of Config.exec_specific
  # * client: DRb handler of the Kadeploy client
  # * db: database handler
  # Output
  # * nothing
  def kaenv_move_files(exec_specific, client, db)
    unless @config.common.almighty_env_users.include?(exec_specific.true_user)
      Debug::distant_client_print(
        "Only the environment administrators can move the files "\
        "in the environments",
        client
      )
      return 1
    end

    res = db.run_query("SELECT * FROM environments")
    unless res.num_rows > 0
      Debug::distant_client_print("There is no recorded environment", client)
      return 1
    end

    #Let's check each environment
    res.each_hash do |row|
      exec_specific.files_to_move.each do |file|
        ['tarball', 'preinstall', 'postinstall'].each do |kind|
          next if !row[kind] or row[kind].empty?
          except = nil
          case kind
          when 'tarball'
            except = FetchFileError::INVALID_ENVIRONMENT_TARBALL
          when 'preinstall'
            except = FetchFileError::INVALID_PREINSTALL
          when 'postinstall'
            except = FetchFileError::INVALID_POSTINSTALL
          end

          update = Proc.new do |updatefile|
            if updatefile['file'] =~ /^#{file['src']}/
              ret = updatefile
              upf = updatefile['file'].gsub(file['src'],'')
              updatefile['file'] = File.join(file['dest'],upf)

              begin
                updatefile['md5'] = Managers::Fetch[updatefile['file'],except,client].checksum
              rescue KadeployError => ke
                msg = KadeployError.to_msg(ke.errno)
                Debug::distant_client_error("#{msg} (error ##{ke.errno})",client) \
                  if msg and !msg.empty?
                client.print(ke.message) if ke.message and !ke.message.empty?
                ret = nil
              end
              ret
            else
              nil
            end
          end

          tmp = EnvironmentManagement::Environment.send(
            "expand_#{kind}".to_sym,row[kind],true
          )
          if tmp.is_a?(Array)
            up = nil
            tmp.each do |t|
              up = update.call(t)
              break unless up
            end
            next unless up
          else
            tmp = update.call(tmp)
          end

          next unless tmp

          res = db.run_query(
            "UPDATE environments SET #{kind} = ? WHERE id = ?",
            EnvironmentManagement::Environment.send(
              "flatten_#{kind}".to_sym,tmp,true
            ),
            row['id']
          )

          if (res.affected_rows > 0)
            Debug::distant_client_print(
              "The environment #{row['name']} version #{row['version']} of "\
              "#{row['user']} has been updated",
              client
            )
          else
            Debug::distant_client_error(
              "The environment #{row['name']} version #{row['version']} of "\
              "#{row['user']} has not been updated",
              client
            )
          end
        end
      end
    end
    return 0
  end






  ##################################
  #           Kaconsole            #
  ##################################

  # Run a Kaconsole command
  #
  # Arguments
  # * db: database handler
  # * client: DRb handler of the Kadeploy client
  # * exec_specific: instance of Config.exec_specific
  # Output
  # * return true if everything is ok, false otherwise  
  def run_kaconsole(db, client, exec_specific, drb_server)
    res = false
    set = Nodes::NodeSet.new
    set.push(exec_specific.node)
    part = @config.cluster_specific[exec_specific.node.cluster].block_device + @config.cluster_specific[exec_specific.node.cluster].deploy_part
    if (CheckRights::CheckRightsFactory.create(@config.common.rights_kind, exec_specific.true_user, client, set, db, part).granted?) then
      thr = Thread.new do
        kill = true
        begin
          client.connect_console(exec_specific.node.cmd.console)
          kill = false
        ensure
          if kill
            client.kill_console()
            Debug::distant_client_print("Lost rights, console killed", client)
          end
        end
      end
      res = true
      while thr.alive?
        unless CheckRights::CheckRightsFactory.create(
          @config.common.rights_kind,
          exec_specific.true_user,
          client, set, db, part
        ).granted?
          thr.kill
          res = false
        end
        sleep 5
      end
      thr.join
    else
      res = false
    end
    db.disconnect()
    drb_server.stop_service()
    return res
  end


  ##################################
  #        Kapower Sync            #
  ##################################
  def run_kapower(output, db, exec_specific, client = nil)
    #We create a new instance of Config with a specific exec_specific part
    config = ConfigInformation::Config.new("empty")
    config.common = @config.common.clone
    config.exec_specific = exec_specific
    config.cluster_specific = Hash.new

    exec_specific.node_set.group_by_cluster.each_key do |cluster|
      config.cluster_specific[cluster] =
        ConfigInformation::ClusterSpecificConfig.new
      @config.cluster_specific[cluster].duplicate_all(
        config.cluster_specific[cluster]
      )
    end

    nodes_ok = Nodes::NodeSet.new
    nodes_ko = Nodes::NodeSet.new
    global_nodes_mutex = Mutex.new
    threads = []

    power_id = Digest::SHA1.hexdigest(
      config.exec_specific.true_user \
      + Time.now.to_s \
      + exec_specific.node_set.to_s
    )
    @power_info_hash_lock.synchronize {
      kapower_add_power_info(power_id, nodes_ok, nodes_ko, false)
    }

    context = {
      :power_id => power_id,
      :database => db,
      :client => client,
      :syslock => @syslog_lock,
      :dblock => @deployments_table_lock,
      :config => config,
      :common => config.common,
      :execution => config.exec_specific,
      :windows => {
        :reboot => @reboot_window,
        :check => @nodes_check_window,
      },
      :nodesets_id => 0,
      :local => { :parent => KadeployServer, :retries => 0 }
    }

    clusters = exec_specific.node_set.group_by_cluster
    if clusters.size > 1
      clid = 1
    else
      clid = 0
    end

    clusters.each_key do |cluster|
      context[:cluster] = config.cluster_specific[cluster]
      if clusters.size > 1
        if context[:cluster].prefix.empty?
          context[:cluster].prefix = "c#{clid}"
          clid += 1
        end
      else
        context[:cluster].prefix = ''
      end
    end

    if clusters.size > 1
      tmp = ''
      clusters.each_key do |cluster|
        tmp += "  #{Debug.prefix(config.cluster_specific[cluster].prefix)}: #{config.cluster_specific[cluster].name}\n"
      end
      output.verbosel(0,"\nClusters involved in the power operation:\n#{tmp}\n",nil,false)
    end

    micros = []
    clusters.each_pair do |cluster, set|
      context[:cluster] = config.cluster_specific[cluster]
      threads << Thread.new do
        micro = CustomMicrostep.new(set, context)
        Thread.current[:micro] = micro
        micros << micro
        micro.debug(0,"Power operation on the nodes #{set.to_s_fold}",nil)
        micro.power(exec_specific.operation, exec_specific.level)
        if not micro.nodes_ok.empty? then
          global_nodes_mutex.synchronize {
            nodes_ok.add(micro.nodes_ok)
          }
        end
        if not micro.nodes_ko.empty? then
          global_nodes_mutex.synchronize {
            nodes_ko.add(micro.nodes_ko)
          }
        end
        micro.debug(0,"Done power operation on the nodes #{set.to_s_fold}",nil)
      end
    end

    if block_given?
      begin
        yield(power_id,threads)
      ensure
        @power_info_hash_lock.synchronize {
          kapower_delete_power_info(power_id)
        }
        config = nil
      end
    else
      [power_id,threads]
    end
  end

  # Run a synchronous Kapower command
  #
  # Arguments
  # * db: database handler
  # * client: DRb handler of the Kadeploy client
  # * exec_specific: instance of Config.exec_specific
  # Output
  # * return true if everything is ok, false otherwise  
  def run_kapower_sync(db, client, exec_specific, drb_server)
    disconnected = false
    if (exec_specific.verbose_level != nil) then
      vl = exec_specific.verbose_level
    else
      vl = @config.common.verbose_level
    end
    output = Debug::OutputControl.new(vl,
      exec_specific.debug, client, exec_specific.true_user, -1,
      @config.common.dbg_to_syslog, @config.common.dbg_to_syslog_level,
      @syslog_lock
    )

    begin
      run_kapower(output, db, exec_specific, client) do |pid,microthreads|
        client.set_workflow_id(pid)
        # Client disconnection fallback
        micros = []
        microthreads.each do |microthread|
          micro = microthread[:micro]
          until micro
            sleep 0.2
            micro = microthread[:micro]
          end
          micros << micro
        end

        finished = false
        finthr = Thread.new do
          while (not finished) do
            begin
              client.test()
            rescue DRb::DRbConnError
              disconnected = true
              output.disable_client_output()
              output.verbosel(3, "Client disconnection")
              microthreads.each { |thread| thread.kill }
              micros.each do |micro|
                micro.output.disable_client_output()
                micro.debug(3,"Kill a power step")
                micro.kill
              end
              @power_info_hash_lock.synchronize {
                kapower_delete_power_info(pid)
              }
              drb_server.stop_service()
              db.disconnect()
              finished = true
            end
            sleep(1)
          end
        end

        # Join threads
        microthreads.each { |thread| thread.join }
        micros.each do |micro|
          clname = micro.context[:cluster].name
          client.print("")
          if not micro.nodes_ok.empty? then
            client.print("Operation correctly performed on cluster #{clname}")
            if (exec_specific.operation != "status") then
              client.print(micro.nodes_ok.to_s(false, false, "\n"))
            else
              client.print(micro.nodes_ok.to_s(true, false, "\n"))
            end
          end
          if not micro.nodes_ko.empty? then
            client.print("Operation not correctly performed on cluster #{clname}")
            client.print(micro.nodes_ko.to_s(false, true, "\n"))
          end
          micro.free
        end
        micros = nil
        finished = true
        finthr.join

        if (not disconnected) then
          client.generate_files(@power_info_hash[pid][0],@power_info_hash[pid][1])
        end
      end
    rescue KadeployError => ke
      msg = KadeployError.to_msg(ke.errno)
      Debug::distant_client_error("#{msg} (error ##{ke.errno})",client) if msg and !msg.empty?
      client.print(ke.message) if ke.message and !ke.message.empty?
      #Debug::distant_client_error("Cannot run the power operation",client)
      @power_info_hash_lock.synchronize {
        kapower_delete_power_info(ke.context[:pid])
      }
    end
    return true
  end



  ##################################
  #        Kapower Async           #
  ##################################

  # Run an asynchronous Kapower command
  #
  # Arguments
  # * db: database handler
  # * exec_specific: instance of Config.exec_specific
  # Output
  # * return a power id
  def run_kapower_async(db, exec_specific)
    output = Debug::OutputControl.new(
      @config.common.verbose_level,
      exec_specific.debug, nil,
      exec_specific.true_user, -1,
      @config.common.dbg_to_syslog,
      @config.common.dbg_to_syslog_level, @syslog_lock
    )
    rid, microthreads = nil
    begin
      rid, microthreads = run_kapower(output, db, exec_specific)
      Thread.new do
        microthreads.each { |thread| thread.join }
        @power_info_hash_lock.synchronize {
          @power_info_hash[rid][2] = true
        }
        if (@config.common.async_end_of_power_hook != "") then
          tmp = cmd = @config.common.async_end_of_power_hook.clone
          while (tmp.sub!("POWER_ID", power_id) != nil)  do
            cmd = tmp
          end
          system(cmd)
        end
        db.disconnect()
      end
    rescue KadeployError => ke
      microthreads.each do |microthread|
        microthread.kill
        microthread[:micro].output.disable_client_output()
        microthread[:micro].debug(3,"Kill a reboot step")
        microthread[:micro].kill
      end
      @power_info_hash_lock.synchronize {
        kapower_delete_power_info(ke.context[:pid])
      }
      begin
        GC.start
      rescue TypeError
      end
      return nil, ke.errno
    end
    return rid, KapowerAsyncError::NO_ERROR
  end

  # Record power information
  #
  # Arguments
  # * power_id: power_id
  # * nodes_ok: nodes ok
  # * nodes_ko: nodes ko
  # * finished: boolean that specify if the operation is finished
  # Output
  # * nothing
  def kapower_add_power_info(power_id, nodes_ok, nodes_ko, finished)
    @power_info_hash[power_id] = [nodes_ok, nodes_ko, finished]
  end

  # Delete power information
  #
  # Arguments
  # * power_id: power id
  # Output
  # * nothing
  def kapower_delete_power_info(power_id)
    @power_info_hash.delete(power_id)
  end
end

# Disable reverse lookup to prevent lag in case of DNS failure
Socket.do_not_reverse_lookup = true

begin
  config = ConfigInformation::Config.new(false)
rescue
  puts "Bad configuration: #{$!}"
  exit(1)
end
db = Database::DbFactory.create(config.common.db_kind)
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
  server = DRb.start_service(uri, kadeployServer)
  server.thread.join
end
