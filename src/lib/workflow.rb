# Kadeploy 3.1
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2012
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

#Kadeploy libs
require 'debug'
require 'nodes'
require 'config'
require 'cache'
require 'macrostep'
require 'stepdeployenv'
require 'stepbroadcastenv'
require 'stepbootnewenv'
require 'md5'
require 'http'
require 'error'
require 'grabfile'
require 'window'

#Ruby libs
require 'thread'
require 'uri'
require 'tempfile'

module Managers
  class MagicCookie
  end

  class TempfileException < RuntimeError
  end

  class MoveException < RuntimeError
  end

  class QueueManager
    @queue_deployment_environment = nil
    @queue_broadcast_environment = nil
    @queue_boot_new_environment = nil
    @queue_process_finished_nodes = nil
    attr_reader :config
    @nodes_ok = nil
    @nodes_ko = nil
    @mutex = nil
    attr_accessor :nb_active_threads

    # Constructor of QueueManager
    #
    # Arguments
    # * config: instance of Config
    # * nodes_ok: NodeSet of nodes OK
    # * nodes_ko: NodeSet of nodes KO
    # Output
    # * nothing
    def initialize(config, nodes_ok, nodes_ko)
      @config = config
      @nodes_ok = nodes_ok
      @nodes_ko = nodes_ko
      @mutex = Mutex.new
      @nb_active_threads = 0
      @queue_deployment_environment = Queue.new
      @queue_broadcast_environment = Queue.new
      @queue_boot_new_environment = Queue.new
      @queue_process_finished_nodes = Queue.new
    end

    # Increment the number of active threads
    #
    # Arguments
    # * nothing
    # Output
    # * nothing
    def increment_active_threads
      @mutex.synchronize {
        @nb_active_threads += 1
      }
    end

    # Decrement the number of active threads
    #
    # Arguments
    # * nothing
    # Output
    # * nothing
    def decrement_active_threads
      @mutex.synchronize {
        @nb_active_threads -= 1
      }
    end

    # Test if the there is only one active thread
    #
    # Arguments
    # * nothing
    # Output
    # * returns true if there is only one active thread
    def one_last_active_thread?
      @mutex.synchronize {
        return (@nb_active_threads == 1)
      }
    end

    # Go to the next macro step in the automata
    #
    # Arguments
    # * current: name of the current macro step (SetDeploymentEnv, BroadcastEnv, BootNewEnv)
    # * nodes: NodeSet that must be involved in the next step
    # Output
    # * raises an exception if a wrong step name is given
    def next_macro_step(current_step, nodes)
      if (nodes.set.empty?)
        raise "Empty node set"
      else
        increment_active_threads
        case current_step
        when nil
          @queue_deployment_environment.push(nodes)
        when "SetDeploymentEnv"
          @queue_broadcast_environment.push(nodes)
        when "BroadcastEnv"
          @queue_boot_new_environment.push(nodes)
        when "BootNewEnv"
          @queue_process_finished_nodes.push(nodes)
        else
          raise "Wrong step name"
        end
      end
    end

    # Replay a step with another instance
    #
    # Arguments
    # * current: name of the current macro step (SetDeploymentEnv, BroadcastEnv, BootNewEnv)
    # * cluster: name of the cluster whose the nodes belongs
    # * nodes: NodeSet that must be involved in the replay
    # Output
    # * returns true if the step can be replayed with another instance, false if no other instance is available
    # * raises an exception if a wrong step name is given    
    def replay_macro_step_with_next_instance(current_step, cluster, nodes)
      macro_step = @config.cluster_specific[cluster].get_macro_step(current_step)
      if not macro_step.use_next_instance then
        return false
      else
        case current_step
        when "SetDeploymentEnv"
          @queue_deployment_environment.push(nodes)
        when "BroadcastEnv"
          @queue_broadcast_environment.push(nodes)
        when "BootNewEnv"
          @queue_boot_new_environment.push(nodes)
        else
          raise "Wrong step name"
        end
        return true
      end
    end

    # Add some nodes in a bad NodeSet
    #
    # Arguments
    # * nodes: NodeSet that must be added in the bad node set
    # Output
    # * nothing
    def add_to_bad_nodes_set(nodes)
      @nodes_ko.add(nodes)
      if one_last_active_thread? then
        #We add an empty node_set to the last state queue
        @queue_process_finished_nodes.push(Nodes::NodeSet.new)
      end
    end

    # Get a new task in the given queue
    #
    # Arguments
    # * queue: name of the queue in which a new task must be taken (SetDeploymentEnv, BroadcastEnv, BootNewEnv, ProcessFinishedNodes)
    # Output
    # * raises an exception if a wrong queue name is given
    def get_task(queue)
      case queue
      when "SetDeploymentEnv"
        return @queue_deployment_environment.pop
      when "BroadcastEnv"
        return @queue_broadcast_environment.pop
      when "BootNewEnv"
        return @queue_boot_new_environment.pop
      when "ProcessFinishedNodes"
        return @queue_process_finished_nodes.pop
      else
        raise "Wrong queue name"
      end
    end

    # Send an exit signal in order to ask the terminaison of the threads (used to avoid deadlock)
    #
    # Arguments
    # * nothing
    # Output
    # * nothing
    def send_exit_signal
      @queue_deployment_environment.push(MagicCookie.new)
      @queue_broadcast_environment.push(MagicCookie.new)
      @queue_boot_new_environment.push(MagicCookie.new) 
      @queue_process_finished_nodes.push(MagicCookie.new)
    end

    # Check if there are some pending events 
    #
    # Arguments
    # * nothing
    # Output
    # * return true if there is no more pending events
    def empty?
      return @queue_deployment_environment.empty? && @queue_broadcast_environment.empty? && 
        @queue_boot_new_environment.empty? && @queue_process_finished_nodes.empty?
    end
  end

  class WorkflowManager
    @thread_set_deployment_environment = nil
    @thread_broadcast_environment = nil
    @thread_boot_new_environment = nil 
    @thread_process_finished_nodes = nil
    @set_deployment_environment_instances = nil
    @broadcast_environment_instances = nil
    @boot_new_environment_instances = nil
    @queue_manager = nil
    attr_accessor :output
    @rights = nil
    @nodeset = nil
    @config = nil
    @client = nil
    @reboot_window = nil
    @nodes_check_window = nil
    @logger = nil
    attr_accessor :db
    @deployments_table_lock = nil
    @mutex = nil
    @thread_tab = nil
    @deploy = nil
    attr_accessor :nodes_ok
    attr_accessor :nodes_ko
    @nodes_to_deploy = nil
    @nodes_to_deploy_backup = nil
    @killed = nil
    @deploy_id = nil
    @async_deployment = nil
    attr_reader :async_file_error

    # Constructor of WorkflowManager
    #
    # Arguments
    # * config: instance of Config
    # * client: Drb handler of the client
    # * reboot_window: instance of WindowManager to manage the reboot window
    # * nodes_check_window: instance of WindowManager to manage the check of the nodes
    # * db: database handler
    # * deployments_table_lock: mutex to protect the deployments table
    # * syslog_lock: mutex on Syslog
    # * deploy_id: deployment id
    # Output
    # * nothing
    def initialize(config, client, reboot_window, nodes_check_window, db, deployments_table_lock, syslog_lock, deploy_id)
      @db = db
      @deployments_table_lock = deployments_table_lock
      @config = config
      @client = client
      @deploy_id = deploy_id
      @async_file_error = FetchFileError::NO_ERROR
      if (@config.exec_specific.verbose_level != nil) then
        @output = Debug::OutputControl.new(@config.exec_specific.verbose_level, @config.exec_specific.debug, client, 
                                           @config.exec_specific.true_user, @deploy_id,
                                           @config.common.dbg_to_syslog, @config.common.dbg_to_syslog_level, syslog_lock)
      else
        @output = Debug::OutputControl.new(@config.common.verbose_level, @config.exec_specific.debug, client,
                                           @config.exec_specific.true_user, @deploy_id,
                                           @config.common.dbg_to_syslog, @config.common.dbg_to_syslog_level, syslog_lock)
      end
      @nodeset = @config.exec_specific.node_set
      @nodes_ok = Nodes::NodeSet.new(@nodeset.id)
      @nodes_ko = Nodes::NodeSet.new(@nodeset.id)
      @queue_manager = QueueManager.new(@config, @nodes_ok, @nodes_ko)
      @reboot_window = reboot_window
      @nodes_check_window = nodes_check_window
      @mutex = Mutex.new
      @set_deployment_environment_instances = Array.new
      @broadcast_environment_instances = Array.new
      @boot_new_environment_instances = Array.new
      @thread_tab = Array.new
      @logger = Debug::Logger.new(@nodeset, @config, @db, 
                                  @config.exec_specific.true_user, @deploy_id, Time.now, 
                                  @config.exec_specific.environment.name + ":" + @config.exec_specific.environment.version.to_s, 
                                  @config.exec_specific.load_env_kind == "file",
                                  syslog_lock)
      @killed = false

      @thread_set_deployment_environment = Thread.new {
        launch_thread_for_macro_step("SetDeploymentEnv")
      }
      @thread_broadcast_environment = Thread.new {
        launch_thread_for_macro_step("BroadcastEnv")
      }
      @thread_boot_new_environment = Thread.new {
        launch_thread_for_macro_step("BootNewEnv")
      }
      @thread_process_finished_nodes = Thread.new {
        launch_thread_for_macro_step("ProcessFinishedNodes")
      }
    end

    private
    # Launch a thread for a macro step
    #
    # Arguments
    # * kind: specifies the kind of macro step to launch
    # Output
    # * nothing  
    def launch_thread_for_macro_step(kind)
      close_thread = false
      @output.verbosel(4, "#{kind} thread launched")
      while (not close_thread) do
        nodes = @queue_manager.get_task(kind)
        #We receive the signal to exit
        if (nodes.kind_of?(MagicCookie)) then
          close_thread = true
        else
          if kind != "ProcessFinishedNodes" then
            nodes.group_by_cluster.each_pair { |cluster, set|
              instance_name,instance_max_retries,instance_timeout = @config.cluster_specific[cluster].get_macro_step(kind).get_instance
              if MacroSteps.typenames.include?(kind)
                ptr = MacroSteps::MacroStepFactory.create(
                  instance_name,
                  instance_max_retries,
                  instance_timeout,
                  cluster,
                  set,
                  @queue_manager,
                  @reboot_window,
                  @nodes_check_window,
                  @output,
                  @logger
                )
                @set_deployment_environment_instances.push(ptr)
                tid = ptr.run
              else
                raise "Invalid macro step name"
              end
              @thread_tab.push(tid)
              #let's free the memory after the launch of the threads
              GC.start
            }
          else
            #in this case, all is ok
            if not nodes.empty? then
              @nodes_ok.add(nodes)
            end
            # Only the first instance that reaches the end has to manage the exit
            if @mutex.try_lock then
              tid = Thread.new {
                while ((not @queue_manager.one_last_active_thread?) || (not @queue_manager.empty?))
                  sleep(1)
                end
                @logger.set("success", true, @nodes_ok)
                @nodes_ok.group_by_cluster.each_pair { |cluster, set|
                  @output.verbosel(0, "Nodes correctly deployed on cluster #{cluster}")
                  @output.verbosel(0, set.to_s(false, false, "\n"))
                }
                @logger.set("success", false, @nodes_ko)
                @logger.error(@nodes_ko)
                @nodes_ko.group_by_cluster.each_pair { |cluster, set|
                  @output.verbosel(0, "Nodes not correctly deployed on cluster #{cluster}")
                  @output.verbosel(0, set.to_s(false, true, "\n"))
                }
                @client.generate_files(@nodes_ok, @nodes_ko) if @client != nil
                Cache::remove_files(@config.common.kadeploy_cache_dir, /#{@config.exec_specific.prefix_in_cache}/, @output) if @config.exec_specific.load_env_kind == "file"
                @logger.dump
                @queue_manager.send_exit_signal
                @thread_set_deployment_environment.join
                @thread_broadcast_environment.join
                @thread_boot_new_environment.join
                if ((@async_deployment) && (@config.common.async_end_of_deployment_hook != "")) then
                  tmp = cmd = @config.common.async_end_of_deployment_hook.clone
                  while (tmp.sub!("WORKFLOW_ID", @deploy_id) != nil)  do
                    cmd = tmp
                  end
                  system(cmd)
                end
              }
              @thread_tab.push(tid)
            else
              @queue_manager.decrement_active_threads
            end
          end
        end
      end
    end

    # Give the local cache filename for a given file
    #
    # Arguments
    # * file: name of the file on the client side
    # Output
    # * return the name of the file in the local cache directory
    def use_local_cache_filename(file, prefix)
      case file
      when /^http[s]?:\/\//
        return File.join(@config.common.kadeploy_cache_dir, prefix + file.slice((file.rindex(File::SEPARATOR) + 1)..(file.length - 1)))
      else
        return File.join(@config.common.kadeploy_cache_dir, prefix + File.basename(file))
      end
    end

    # Grab files from the client side (tarball, ssh public key, preinstall, user postinstall, files for custom operations)
    #
    # Arguments
    # * async (opt) : specify if the caller client is asynchronous
    # Output
    # * return true if the files have been successfully grabbed, false otherwise
    def grab_user_files(async = false)
      env_prefix = @config.exec_specific.prefix_in_cache
      user_prefix = "u-#{@config.exec_specific.true_user}--"
      tarball = @config.exec_specific.environment.tarball
      local_tarball = use_local_cache_filename(tarball["file"], env_prefix)
      
      gfm = GrabFileManager.new(@config, @output, @client, @db)

      begin
        if not gfm.grab_file(tarball["file"], local_tarball, tarball["md5"], "tarball", env_prefix, 
                             @config.common.kadeploy_cache_dir, @config.common.kadeploy_cache_size, async) then 
          @async_file_error = FetchFileError::INVALID_ENVIRONMENT_TARBALL if async
          return false
        end
      rescue TempfileException
        @async_file_error = FetchFileError::TEMPFILE_CANNOT_BE_CREATED_IN_CACHE if async
        return false
      rescue MoveException
        @async_file_error = FetchFileError::FILE_CANNOT_BE_MOVED_IN_CACHE if async
        return false      
      end

      tarball["file"] = local_tarball

      if @config.exec_specific.key != "" then
        key = @config.exec_specific.key
        local_key = use_local_cache_filename(key, user_prefix)
        begin
          if not gfm.grab_file_without_caching(key, local_key, "key", user_prefix, @config.common.kadeploy_cache_dir, 
                                               @config.common.kadeploy_cache_size, async) then
            @async_file_error = FetchFileError::INVALID_KEY if async
            return false
          end
        rescue TempfileException
          @async_file_error = FetchFileError::TEMPFILE_CANNOT_BE_CREATED_IN_CACHE if async
          return false
        rescue MoveException
          @async_file_error = FetchFileError::FILE_CANNOT_BE_MOVED_IN_CACHE if async
          return false  
        end

        @config.exec_specific.key = local_key
      end

      if (@config.exec_specific.environment.preinstall != nil) then
        preinstall = @config.exec_specific.environment.preinstall
        local_preinstall =  use_local_cache_filename(preinstall["file"], env_prefix)
        begin
          if not gfm.grab_file(preinstall["file"], local_preinstall, preinstall["md5"], "preinstall", env_prefix, 
                               @config.common.kadeploy_cache_dir, @config.common.kadeploy_cache_size,async) then 
            @async_file_error = FetchFileError::INVALID_PREINSTALL if async
            return false
          end
        rescue TempfileException
          @async_file_error = FetchFileError::TEMPFILE_CANNOT_BE_CREATED_IN_CACHE if async
          return false
        rescue MoveException
          @async_file_error = FetchFileError::FILE_CANNOT_BE_MOVED_IN_CACHE if async
          return false  
        end
        if (File.size(local_preinstall) / (1024.0 * 1024.0)) > @config.common.max_preinstall_size then
          @output.verbosel(0, "The preinstall file #{preinstall["file"]} is too big (#{@config.common.max_preinstall_size} MB is the maximum size allowed)")
          File.delete(local_preinstall)
          @async_file_error = FetchFileError::PREINSTALL_TOO_BIG if async
          return false
        end
        preinstall["file"] = local_preinstall
      end
      
      if (@config.exec_specific.environment.postinstall != nil) then
        @config.exec_specific.environment.postinstall.each { |postinstall|
          local_postinstall = use_local_cache_filename(postinstall["file"], env_prefix)
          begin
            if not gfm.grab_file(postinstall["file"], local_postinstall, postinstall["md5"], "postinstall", env_prefix, 
                                 @config.common.kadeploy_cache_dir, @config.common.kadeploy_cache_size, async) then 
              @async_file_error = FetchFileError::INVALID_POSTINSTALL if async
              return false
            end
          rescue TempfileException
            @async_file_error = FetchFileError::TEMPFILE_CANNOT_BE_CREATED_IN_CACHE if async
            return false
          rescue MoveException
            @async_file_error = FetchFileError::FILE_CANNOT_BE_MOVED_IN_CACHE if async
            return false  
          end
          if (File.size(local_postinstall) / (1024.0 * 1024.0)) > @config.common.max_postinstall_size then
            @output.verbosel(0, "The postinstall file #{postinstall["file"]} is too big (#{@config.common.max_postinstall_size} MB is the maximum size allowed)")
            File.delete(local_postinstall)
            @async_file_error = FetchFileError::POSTINSTALL_TOO_BIG if async
            return false
          end
          postinstall["file"] = local_postinstall
        }
      end

      if (@config.exec_specific.custom_operations != nil) then
        @config.exec_specific.custom_operations.each_key { |macro_step|
          @config.exec_specific.custom_operations[macro_step].each_key { |micro_step|
            @config.exec_specific.custom_operations[macro_step][micro_step].each { |entry|
              if (entry[0] == "send") then
                custom_file = entry[1]
                local_custom_file = use_local_cache_filename(custom_file, user_prefix)
                begin
                  if not gfm.grab_file_without_caching(custom_file, local_custom_file, "custom_file", 
                                                       user_prefix, @config.common.kadeploy_cache_dir, 
                                                       @config.common.kadeploy_cache_size, async) then
                    @async_file_error = FetchFileError::INVALID_CUSTOM_FILE if async
                    return false
                  end
                rescue TempfileException
                  @async_file_error = FetchFileError::TEMPFILE_CANNOT_BE_CREATED_IN_CACHE if async
                  return false
                rescue MoveException
                  @async_file_error = FetchFileError::FILE_CANNOT_BE_MOVED_IN_CACHE if async
                  return false  
                end
                entry[1] = local_custom_file
              end
            }
          }
        }
      end

      if @config.exec_specific.pxe_profile_msg != "" then
        if not @config.exec_specific.pxe_upload_files.empty? then
          @config.exec_specific.pxe_upload_files.each { |pxe_file|
            user_prefix = "pxe-#{@config.exec_specific.true_user}--"
            local_pxe_file = File.join(@config.common.pxe_repository, 
                                       @common.pxe_repository_kernels,
                                       "#{user_prefix}#{File.basename(pxe_file)}")
            begin
              if not gfm.grab_file_without_caching(pxe_file, local_pxe_file, "pxe_file", user_prefix,
                                                   File.join(@config.common.pxe_repository,
                                                             @common.pxe_repository_kernels), 
                                                   @config.common.pxe_repository_kernels_max_size, async) then
                @async_file_error = FetchFileError::INVALID_PXE_FILE if async
                return false
              end
            rescue TempfileException
              @async_file_error = FetchFileError::TEMPFILE_CANNOT_BE_CREATED_IN_CACHE if async
              return false
            rescue MoveException
              @async_file_error = FetchFileError::FILE_CANNOT_BE_MOVED_IN_CACHE if async
              return false  
            end
          }
        end
      end

      return true
    end

    public

    # Prepare a deployment
    #
    # Arguments
    # * nothing
    # Output
    # * return true in case of success, false otherwise
    def prepare
      @output.verbosel(0, "Launching a deployment ...")
      @deployments_table_lock.lock
      if (@config.exec_specific.ignore_nodes_deploying) then
        @nodes_to_deploy = @nodeset
      else
        @nodes_to_deploy,nodes_to_discard = @nodeset.check_nodes_in_deployment(@db, @config.common.purge_deployment_timer)
        if (not nodes_to_discard.empty?) then
          @output.verbosel(0, "The nodes #{nodes_to_discard.to_s} are already involved in deployment, let's discard them")
          nodes_to_discard.make_array_of_hostname.each { |hostname|
            @config.set_node_state(hostname, "", "", "discarded")
          }
        end
      end
      #We backup the set of nodes used in the deployement to be able to update their deployment state at the end of the deployment
      if not @nodes_to_deploy.empty? then
        @nodes_to_deploy_backup = Nodes::NodeSet.new
        @nodes_to_deploy.duplicate(@nodes_to_deploy_backup)
        #If the environment is not recorded in the DB (anonymous environment), we do not record an environment id in the node state
        if @config.exec_specific.load_env_kind == "file" then
          @nodes_to_deploy.set_deployment_state("deploying", -1, @db, @config.exec_specific.true_user)
        else
          @nodes_to_deploy.set_deployment_state("deploying", @config.exec_specific.environment.id, @db, @config.exec_specific.true_user)
        end
        @deployments_table_lock.unlock
        return true
      else
        @deployments_table_lock.unlock
        @output.verbosel(0, "All the nodes have been discarded ...")
        return false
      end
    end

    # Grab eventually some file from the client side
    #
    # Arguments
    # * async (opt) : specify if the caller client is asynchronous
    # Output
    # * return true in case of success, false otherwise
    def manage_files(async = false)
      #We set the prefix of the files in the cache
      if @config.exec_specific.load_env_kind == "file" then
        @config.exec_specific.prefix_in_cache = "e-anon-#{@config.exec_specific.true_user}-#{Time.now.to_i}--"
      else
        @config.exec_specific.prefix_in_cache = "e-#{@config.exec_specific.environment.id}--"
      end
      if (@config.common.kadeploy_disable_cache || grab_user_files(async)) then
        return true
      else
        @nodes_to_deploy.set_deployment_state("aborted", nil, @db, "")
        return false
      end
    end

    # Run a workflow synchronously
    #
    # Arguments
    # * nothing
    # Output
    # * nothing
    def run_sync
      @async_deployment = false
      @nodes_to_deploy.group_by_cluster.each_pair { |cluster, set|
        @queue_manager.next_macro_step(nil, set)
      }
      @thread_process_finished_nodes.join
      if not @killed then
        @deployments_table_lock.synchronize {
          @nodes_ok.set_deployment_state("deployed", nil, @db, "")
          @nodes_ko.set_deployment_state("deploy_failed", nil, @db, "")
        }
      end
      @nodes_to_deploy_backup = nil
    end

    # Run a workflow asynchronously
    #
    # Arguments
    # * nothing
    # Output
    def run_async
      Thread.new {
        @async_deployment = true
        if manage_files(true) then
          @nodes_to_deploy.group_by_cluster.each_pair { |cluster, set|
            @queue_manager.next_macro_step(nil, set)
          }
        else
          if (@config.common.async_end_of_deployment_hook != "") then
            tmp = cmd = @config.common.async_end_of_deployment_hook.clone
            while (tmp.sub!("WORKFLOW_ID", @deploy_id) != nil)  do
              cmd = tmp
            end
            system(cmd)
          end
        end
      }
    end

    # Test if the workflow has reached the end
    #
    # Arguments
    # * nothing
    # Output
    # * return true if the workflow has reached the end, false otherwise
    def ended?
      if (@async_file_error > FetchFileError::NO_ERROR) || (@thread_process_finished_nodes.status == false) then
        if not @killed then
          if (@nodes_to_deploy_backup != nil) then #it may be called several time in async mode
            @deployments_table_lock.synchronize {
              @nodes_ok.set_deployment_state("deployed", nil, @db, "")
              @nodes_ko.set_deployment_state("deploy_failed", nil, @db, "")
            }
          end
        end
        @nodes_to_deploy_backup = nil
        return true
      else
        return false
      end
    end

    # Get the results of a workflow (RPC: only for async execution)
    #
    # Arguments
    # * nothing
    # Output
    # * return a hastable containing the state of all the nodes involved in the deployment
    def get_results
      return Hash["nodes_ok" => @nodes_ok.to_h, "nodes_ko" => @nodes_ko.to_h]
    end

    # Get the state of a deployment workflow
    #
    # Arguments
    # * nothing
    # Output
    # * retun a hashtable containing the state of a deployment workflow
    def get_state
      hash = Hash.new
      hash["user"] = @config.exec_specific.true_user
      hash["deploy_id"] = @deploy_id
      hash["environment_name"] = @config.exec_specific.environment.name
      hash["environment_version"] = @config.exec_specific.environment.version
      hash["environment_user"] = @config.exec_specific.user
      hash["anonymous_environment"] = (@config.exec_specific.load_env_kind == "file")
      hash["nodes"] = @config.exec_specific.nodes_state
      return hash
    end

    # Finalize a deployment workflow
    #
    # Arguments
    # * nothing
    # Output
    # * nothing
    def finalize
      @db = nil
      @deployments_table_lock = nil
      @config = nil
      @client = nil
      @output = nil
      @nodes_ok.free()
      @nodes_ko.free()
      @nodes_ok = nil
      @nodes_ko = nil
      @nodeset = nil
      @queue_manager = nil
      @reboot_window = nil
      @mutex = nil
      @set_deployment_environment_instances = nil
      @broadcast_environment_instances = nil
      @boot_new_environment_instances = nil
      @thread_tab = nil
      @logger = nil
      @thread_set_deployment_environment = nil
      @thread_broadcast_environment = nil
      @thread_boot_new_environment = nil
      @thread_process_finished_nodes = nil
    end

    # Kill all the threads of a Kadeploy workflow
    #
    # Arguments
    # * nothing
    # Output
    # * nothing
    def kill
      @output.verbosel(0, "Deployment aborted by user")
      @killed = true
      @logger.set("success", false, @nodeset)
      @logger.dump
      @nodeset.set_deployment_state("aborted", nil, @db, "")
      @set_deployment_environment_instances.each { |instance|
        if (instance != nil) then
          instance.kill()
          @output.verbosel(3, " *** Kill a set_deployment_environment_instance")
        end
      }
      @broadcast_environment_instances.each { |instance|
        if (instance != nil) then
          @output.verbosel(3, " *** Kill a broadcast_environment_instance")
          instance.kill()
        end
      }
      @boot_new_environment_instances.each { |instance|
        if (instance != nil) then
          @output.verbosel(3, " *** Kill a boot_new_environment_instance")
          instance.kill()
        end
      }
      @thread_tab.each { |tid|
        @output.verbosel(3, " *** Kill a main thread")
        Thread.kill(tid)
      }
      Thread.kill(@thread_set_deployment_environment)
      Thread.kill(@thread_broadcast_environment)
      Thread.kill(@thread_boot_new_environment)
      Thread.kill(@thread_process_finished_nodes)
    end
  end
end
