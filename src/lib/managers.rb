# Kadeploy 3.1
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2010
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

#Kadeploy libs
require 'debug'
require 'nodes'
require 'config'
require 'cache'
require 'stepdeployenv'
require 'stepbroadcastenv'
require 'stepbootnewenv'
require 'md5'
require 'http'
require 'error'

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

  class GrabFileManager
    @config = nil
    @output = nil
    @client = nil
    @db = nil

    # Constructor of GrabFileManager
    #
    # Arguments
    # * config: instance of Config
    # * output: instance of OutputControl
    # * client : Drb handler of the client
    # * db: database handler
    # Output
    # * nothing
    def initialize(config, output, client, db)
      @config = config
      @output = output
      @client = client
      @db = db
    end

    # Grab a file from the client side or locally with recording the hash of the file
    #
    # Arguments
    # * client_file: client file to grab
    # * local_file: path to local cached file
    # * expected_md5: expected md5 for the client file
    # * file_tag: tag used to specify the kind of file to grab
    # * prefix: prefix used to store the file in the cache
    # * cache_dir: cache directory
    # * cache_size: cache size
    # * async (opt) : specify if the caller client is asynchronous
    # Output
    # * return true if everything is successfully performed, false otherwise
    def grab_file_with_caching(client_file, local_file, expected_md5, file_tag, prefix, cache_dir, cache_size, async = false)
      #http fetch
      if (client_file =~ /^http[s]?:\/\//) then
        @output.verbosel(3, "Grab the #{file_tag} file #{client_file} over http")
        file_size = HTTP::get_file_size(client_file)
        if file_size == nil then
          @output.verbosel(0, "Cannot reach the file at #{client_file}")
          return false
        end
        Cache::clean_cache(cache_dir,
                           (cache_size * 1024 * 1024) -  file_size,
                           0.5, /./,
                           @output)
        if (not File.exist?(local_file)) then
          resp,etag = HTTP::fetch_file(client_file, local_file, cache_dir, nil)
          case resp
          when -1
            @output.verbosel(0, "Tempfiles cannot be created")
            raise TempfileException
          when -2
            @output.verbosel(0, "Environment file cannot be moved")
            raise MoveException
          when "200"
            @output.verbosel(4, "File #{client_file} fetched")
          else
            @output.verbosel(0, "Cannot fetch the file at #{client_file}, http error #{resp}")
            return false
          end

          if not @config.exec_specific.environment.set_md5(file_tag, client_file, etag.gsub("\"",""), @db) then
            @output.verbosel(0, "Cannot update the md5 of #{client_file}")
            return false
          end
        else
          resp,etag = HTTP::fetch_file(client_file, local_file, cache_dir, expected_md5)
          case resp
          when -1
            @output.verbosel(0, "Tempfiles cannot be created")
            raise TempfileException
          when -2
            @output.verbosel(0, "Environment file cannot be moved")
            raise MoveException
          when "200"
            @output.verbosel(4, "File #{client_file} fetched")
            if not @config.exec_specific.environment.set_md5(file_tag, client_file, etag.gsub("\"",""), @db) then
              @output.verbosel(0, "Cannot update the md5 of #{client_file}")
              return false
            end
          when "304"
            @output.verbosel(4, "File #{client_file} already in cache")
            if not system("touch -a #{local_file}") then
              @output.verbosel(0, "Unable to touch the local file")
              return false
            end
          else
            @output.verbosel(0, "Cannot fetch the file at #{client_file}, http error: #{resp}")
            return false
          end
        end
      #classical fetch
      else
        if ((not File.exist?(local_file)) || (MD5::get_md5_sum(local_file) != expected_md5)) then
          #We first check if the file can be reached locally
          if (File.readable?(client_file) && (MD5::get_md5_sum(client_file) == expected_md5)) then
            Cache::clean_cache(cache_dir,
                               (cache_size * 1024 * 1024) -  File.stat(client_file).size,
                               0.5, /./,
                               @output)
            @output.verbosel(3, "Do a local copy for the #{file_tag} file #{client_file}")
            if not system("cp #{client_file} #{local_file}") then
              @output.verbosel(0, "Unable to do the local copy (#{client_file} to #{local_file})")
              return false
            else
              if not system("chmod 640 #{local_file}") then
                @output.verbosel(0, "Unable to change the rights on #{local_file}")
                return false
              end
            end
          else
            if async then
              @output.verbosel(0, "Only http transfer is allowed in asynchronous mode")
              return false
            else
              Cache::clean_cache(cache_dir,
                                 (cache_size * 1024 * 1024) - @client.get_file_size(client_file),
                                 0.5, /./,
                                 @output)
              @output.verbosel(3, "Grab the #{file_tag} file #{client_file}")
              if (@client.get_file_md5(client_file) != expected_md5) then
                @output.verbosel(0, "The md5 of #{client_file} does not match with the one recorded in the database, please consider to update your environment")
                return false
              end
              if not @client.get_file(client_file, prefix, cache_dir) then
                @output.verbosel(0, "Unable to grab the #{file_tag} file #{client_file}")
                return false
              end
            end
          end
        else
          if (not async) then
            if (File.readable?(client_file)) then
              #the file is reachable on the local filesystem
              get_mtime = lambda { return File.mtime(client_file).to_i }
              get_md5 = lambda { return MD5::get_md5_sum(client_file) }
            else
              #the file is only reachable by the client
              get_mtime = lambda { return @client.get_file_mtime(client_file) }
              get_md5 = lambda { return @client.get_file_md5(client_file) }
            end
            if (File.mtime(local_file).to_i < get_mtime.call) then
              if (get_md5.call  != expected_md5) then
                @output.verbosel(0, "!!! Warning !!! The file #{client_file} has been modified, you should run kaenv3 to update its MD5")
              else
                if not system("touch -m #{local_file}") then
                  @output.verbosel(0, "Unable to touch the local file")
                  return false
                end
              end
            end
          end
          if not system("touch -a #{local_file}") then
            @output.verbosel(0, "Unable to touch the local file")
            return false
          end
        end
      end
      return true
    end

    # Grab a file from the client side or locally without recording the hash of the file
    #
    # Arguments
    # * client_file: client file to grab
    # * local_file: path to local cached file
    # * file_tag: tag used to specify the kind of file to grab
    # * prefix: prefix used to store the file in the cache
    # * cache_dir: cache directory
    # * cache_size: cache size
    # * async (opt) : specify if the caller client is asynchronous
    # Output
    # * return true if everything is successfully performed, false otherwise
    def grab_file_without_caching(client_file, local_file, file_tag, prefix, cache_dir, cache_size, async)
      #http fetch
      if (client_file =~ /^http[s]?:\/\//) then
        @output.verbosel(3, "Grab the #{file_tag} file #{client_file} over http")
        file_size = HTTP::get_file_size(client_file)
        if file_size == nil then
          @output.verbosel(0, "Cannot reach the file at #{client_file}")
          return false
        end
        Cache::clean_cache(cache_dir,
                           (cache_size * 1024 * 1024) -  file_size,
                           0.5, /./,
                           @output)
        resp,etag = HTTP::fetch_file(client_file, local_file, cache_dir, nil)
        case resp
        when -1
          @output.verbosel(0, "Tempfiles cannot be created")
          raise TempfileException
        when -2
          @output.verbosel(0, "Environment file cannot be moved")
          raise MoveException
        when "200"
          @output.verbosel(4, "File #{client_file} fetched")
        else
          @output.verbosel(0, "Unable to grab the #{file_tag} file #{client_file}, http error #{resp}")
          return false
        end
      #classical fetch
      else
        if File.readable?(client_file) then
          Cache::clean_cache(cache_dir,
                             (cache_size * 1024 * 1024) -  File.stat(client_file).size,
                             0.5, /./,
                             @output)
          @output.verbosel(3, "Do a local copy for the #{file_tag} file #{client_file}")
          if not system("cp #{client_file} #{local_file}") then
            @output.verbosel(0, "Unable to do the local copy (#{client_file} to #{local_file})")
            return false
          else
            if not system("chmod 640 #{local_file}") then
              @output.verbosel(0, "Unable to change the rights on #{local_file}")
              return false
            end
          end
        else
          if async then
            @output.verbosel(0, "Only http transfer is allowed in asynchronous mode")
            return false
          else
            @output.verbosel(3, "Grab the #{file_tag} file #{client_file}")
            Cache::clean_cache(cache_dir,
                               (cache_size * 1024 * 1024) - @client.get_file_size(client_file),
                               0.5, /./,
                               @output)
            if not @client.get_file(client_file, prefix, cache_dir) then
              @output.verbosel(0, "Unable to grab the file #{client_file}")
              return false
            end
          end
        end
      end
      return true
    end

    # Grab a file from the client side or locally
    #
    # Arguments
    # * client_file: client file to grab
    # * local_file: path to local cached file
    # * expected_md5: expected md5 for the client file
    # * file_tag: tag used to specify the kind of file to grab
    # * prefix: prefix used to store the file in the cache
    # * cache_dir: cache directory
    # * cache_size: cache size
    # * async (opt) : specify if the caller client is asynchronous
    # Output
    # * return true if everything is successfully performed, false otherwise
    def grab_file(client_file, local_file, expected_md5, file_tag, prefix, cache_dir, cache_size, async = false)
      #anonymous environment
      if (@config.exec_specific.load_env_kind == "file") then
        return grab_file_without_caching(client_file, local_file, file_tag, prefix, cache_dir, cache_size, async)
      #recorded environement
      else
        return grab_file_with_caching(client_file, local_file, expected_md5, file_tag, prefix, cache_dir, cache_size, async)
      end
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
      @nodes_ok = Nodes::NodeSet.new
      @nodes_ko = Nodes::NodeSet.new
      @nodeset = @config.exec_specific.node_set
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
                                  @config.exec_specific.environment.name + ":" + @config.exec_specific.environment.version, 
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
              case kind
              when "SetDeploymentEnv"
                ptr = SetDeploymentEnvironnment::SetDeploymentEnvFactory.create(instance_name, 
                                                                                instance_max_retries,
                                                                                instance_timeout,
                                                                                cluster,
                                                                                set,
                                                                                @queue_manager,
                                                                                @reboot_window,
                                                                                @nodes_check_window,
                                                                                @output,
                                                                                @logger)
                @set_deployment_environment_instances.push(ptr)
                tid = ptr.run
              when "BroadcastEnv"
                ptr = BroadcastEnvironment::BroadcastEnvFactory.create(instance_name, 
                                                                       instance_max_retries, 
                                                                       instance_timeout,
                                                                       cluster,
                                                                       set,
                                                                       @queue_manager,
                                                                       @reboot_window,
                                                                       @nodes_check_window,
                                                                       @output,
                                                                       @logger)
                @broadcast_environment_instances.push(ptr)
                tid = ptr.run
              when "BootNewEnv"
                ptr = BootNewEnvironment::BootNewEnvFactory.create(instance_name, 
                                                                   instance_max_retries,
                                                                   instance_timeout,
                                                                   cluster,
                                                                   set,
                                                                   @queue_manager,
                                                                   @reboot_window,
                                                                   @nodes_check_window,
                                                                   @output,
                                                                   @logger)
                @boot_new_environment_instances.push(ptr)
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
            tftp_images_path = "#{@config.common.tftp_repository}/#{@config.common.tftp_images_path}"
            local_pxe_file = "#{tftp_images_path}/#{user_prefix}#{File.basename(pxe_file)}"
            begin
              if not gfm.grab_file_without_caching(pxe_file, local_pxe_file, "pxe_file",
                                                   user_prefix, tftp_images_path, 
                                                   @config.common.tftp_images_max_size, async) then
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
