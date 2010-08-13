# Kadeploy 3.1
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2010
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

#Kadelpoy libs
require 'debug'

module BroadcastEnvironment
  class BroadcastEnvFactory
    # Factory for the methods to broadcast an environment
    #
    # Arguments
    # * kind: specifies the method to use (BroadcastEnvChainWithFS, BroadcastEnvTreeWithFS, BroadcastEnvDummy)
    # * max_retries: maximum number of retries for the step
    # * timeout: timeout for the step
    # * cluster: name of the cluster
    # * nodes: instance of NodeSet
    # * queue_manager: instance of QueueManager
    # * reboot_window: instance of WindowManager
    # * nodes_check_window: instance of WindowManager
    # * output: instance of OutputControl
    # * logger: instance of Logger
    # Output
    # * returns a BroadcastEnv instance (BroadcastEnvChainWithFS, BroadcastEnvTreeWithFS, BroadcastEnvDummy)
    # * raises an exception if an invalid kind of instance is given
    def BroadcastEnvFactory.create(kind, max_retries, timeout, cluster, nodes, queue_manager, reboot_window, nodes_check_window, output, logger)
      begin
        klass = BroadcastEnvironment::class_eval(kind)
      rescue NameError
        raise "Invalid kind of step value for the environment broadcast step"
      end
      return klass.new(max_retries, timeout, cluster, nodes, queue_manager, reboot_window, nodes_check_window, output, logger)
    end
  end

  class BroadcastEnv
    @remaining_retries = 0
    @timeout = 0
    @queue_manager = nil
    @config = nil
    @reboot_window = nil
    @nodes_check_window = nil
    @output = nil
    @cluster = nil
    @nodes = nil
    @nodes_ok = nil
    @nodes_ko = nil
    @step = nil
    @start = nil
    @instances = nil

    # Constructor of BroadcastEnv
    #
    # Arguments
    # * max_retries: maximum number of retries for the step
    # * timeout: timeout for the step
    # * cluster: name of the cluster
    # * nodes: instance of NodeSet
    # * queue_manager: instance of QueueManager
    # * reboot_window: instance of WindowManager
    # * nodes_check_window: instance of WindowManager
    # * output: instance of OutputControl
    # * logger: instance of Logger
    # Output
    # * nothing
    def initialize(max_retries, timeout, cluster, nodes, queue_manager, reboot_window, nodes_check_window, output, logger)
      @remaining_retries = max_retries
      @timeout = timeout
      @nodes = nodes
      @queue_manager = queue_manager
      @config = @queue_manager.config
      @reboot_window = reboot_window
      @nodes_check_window = nodes_check_window
      @output = output
      @nodes_ok = Nodes::NodeSet.new
      @nodes_ko = Nodes::NodeSet.new
      @cluster = cluster
      @logger = logger
      @logger.set("step2", get_instance_name, @nodes)
      @logger.set("timeout_step2", @timeout, @nodes)
      @instances = Array.new
      @start = Time.now.to_i
      @step = MicroStepsLibrary::MicroSteps.new(@nodes_ok, @nodes_ko, @reboot_window, @nodes_check_window, @config, cluster, output, get_instance_name)
    end

    def finalize
      @queue_manager = nil
      @config = nil
      @reboot_window = nil
      @nodes_check_window = nil
      @output = nil
      @nodes_ok = nil
      @nodes_ko = nil
      @cluster = nil
      @logger = nil
      @instances.delete_if { |i| true }
      @instances = nil
      @start = nil
      @step = nil
    end

    # Kill all the running threads
    #
    # Arguments
    # * nothing
    # Output
    # * nothing
    def kill
      if (@instances != nil) then
        @instances.each { |tid|
          #first, we clean all the pending processes
          @step.process_container.killall(tid)
          #then, we kill the thread
          Thread.kill(tid)
        }
      end
    end

    # Get the name of the current macro step
    #
    # Arguments
    # * nothing
    # Output
    # * returns the name of the current macro step  
    def get_macro_step_name
      return self.class.superclass.to_s.split("::")[1]
    end

    # Get the name of the current instance
    #
    # Arguments
    # * nothing
    # Output
    # * returns the name of the current current instance
    def get_instance_name
      return self.class.to_s.split("::")[1]
    end
  end

  class BroadcastEnvChain < BroadcastEnv
    # Main of the BroadcastEnvChain instance
    #
    # Arguments
    # * nothing
    # Output
    # * return a thread id
    def run
      tid = Thread.new {
        if @config.exec_specific.breakpointed
          @queue_manager.next_macro_step(get_macro_step_name, @nodes)
        else
          @nodes.duplicate_and_free(@nodes_ko)
        end
        while (@remaining_retries > 0) && (not @nodes_ko.empty?) && (not @config.exec_specific.breakpointed)
          instance_node_set = Nodes::NodeSet.new
          @nodes_ko.duplicate(instance_node_set)
          instance_thread = Thread.new {
            @logger.increment("retry_step2", @nodes_ko)
            @nodes_ko.duplicate_and_free(@nodes_ok)
            @output.verbosel(1, "Performing a BroadcastEnvChain step on the nodes: #{@nodes_ok.to_s_fold}")
            result = true
            #Here are the micro steps
            result = result && @step.send_environment("chain")
            result = result && @step.manage_admin_post_install("tree")
            result = result && @step.manage_user_post_install("tree")
            result = result && @step.send_key("tree")
            result = result && @step.install_bootloader
            #End of micro steps
          }
          @instances.push(instance_thread)
          if not @step.timeout?(@timeout, instance_thread, get_macro_step_name, instance_node_set) then
            if not @nodes_ok.empty? then
              @logger.set("step2_duration", Time.now.to_i - @start, @nodes_ok)
              @nodes_ok.duplicate_and_free(instance_node_set)
              @queue_manager.next_macro_step(get_macro_step_name, instance_node_set)
            end
          end
          @remaining_retries -= 1
        end
        #After several retries, some nodes may still be in an incorrect state
        if (not @nodes_ko.empty?) && (not @config.exec_specific.breakpointed) then
          #Maybe some other instances are defined
          if not @queue_manager.replay_macro_step_with_next_instance(get_macro_step_name, @cluster, @nodes_ko)
            @queue_manager.add_to_bad_nodes_set(@nodes_ko)
            @queue_manager.decrement_active_threads
          end
        else
          @queue_manager.decrement_active_threads
        end
        finalize()
      }
      return tid
    end
  end

  class BroadcastEnvKastafior < BroadcastEnv
    # Main of the BroadcastEnvKastafior instance
    #
    # Arguments
    # * nothing
    # Output
    # * return a thread id
    def run
      tid = Thread.new {
        if @config.exec_specific.breakpointed
          @queue_manager.next_macro_step(get_macro_step_name, @nodes)
        else
          @nodes.duplicate_and_free(@nodes_ko)
        end
        while (@remaining_retries > 0) && (not @nodes_ko.empty?) && (not @config.exec_specific.breakpointed)
          instance_node_set = Nodes::NodeSet.new
          @nodes_ko.duplicate(instance_node_set)
          instance_thread = Thread.new {
            @logger.increment("retry_step2", @nodes_ko)
            @nodes_ko.duplicate_and_free(@nodes_ok)
            @output.verbosel(1, "Performing a BroadcastEnvKastafior step on the nodes: #{@nodes_ok.to_s_fold}")
            result = true
            #Here are the micro steps
            result = result && @step.send_environment("kastafior")
            result = result && @step.manage_admin_post_install("tree")
            result = result && @step.manage_user_post_install("tree")
            result = result && @step.send_key("tree")
            result = result && @step.install_bootloader
            #End of micro steps
          }
          @instances.push(instance_thread)
          if not @step.timeout?(@timeout, instance_thread, get_macro_step_name, instance_node_set) then
            if not @nodes_ok.empty? then
              @logger.set("step2_duration", Time.now.to_i - @start, @nodes_ok)
              @nodes_ok.duplicate_and_free(instance_node_set)
              @queue_manager.next_macro_step(get_macro_step_name, instance_node_set)
            end
          end
          @remaining_retries -= 1
        end
        #After several retries, some nodes may still be in an incorrect state
        if (not @nodes_ko.empty?) && (not @config.exec_specific.breakpointed) then
          #Maybe some other instances are defined
          if not @queue_manager.replay_macro_step_with_next_instance(get_macro_step_name, @cluster, @nodes_ko)
            @queue_manager.add_to_bad_nodes_set(@nodes_ko)
            @queue_manager.decrement_active_threads
          end
        else
          @queue_manager.decrement_active_threads
        end
        finalize()
      }
      return tid
    end
  end

  class BroadcastEnvTree < BroadcastEnv
    # Main of the BroadcastEnvTree instance
    #
    # Arguments
    # * nothing
    # Output
    # * return a thread id
    def run
      tid = Thread.new {
        if @config.exec_specific.breakpointed
          @queue_manager.next_macro_step(get_macro_step_name, @nodes)
        else
          @nodes.duplicate_and_free(@nodes_ko)
        end
        while (@remaining_retries > 0) && (not @nodes_ko.empty?) && (not @config.exec_specific.breakpointed)
          instance_node_set = Nodes::NodeSet.new
          @nodes_ko.duplicate(instance_node_set)
          instance_thread = Thread.new {
            @logger.increment("retry_step2", @nodes_ko)
            @nodes_ko.duplicate_and_free(@nodes_ok)
            @output.verbosel(1, "Performing a BroadcastEnvChain step on the nodes: #{@nodes_ok.to_s_fold}")
            result = true
            #Here are the micro steps 
            result = result && @step.send_environment("tree")
            result = result && @step.manage_admin_post_install("tree")
            result = result && @step.manage_user_post_install("tree")
            result = result && @step.send_key("tree")
            result = result && @step.install_bootloader
            #End of micro steps
          }
          @instances.push(instance_thread)
          if not @step.timeout?(@timeout, instance_thread, get_macro_step_name, instance_node_set) then
            if not @nodes_ok.empty? then
              @logger.set("step2_duration", Time.now.to_i - @start, @nodes_ok)
              @nodes_ok.duplicate_and_free(instance_node_set)
              @queue_manager.next_macro_step(get_macro_step_name, instance_node_set)
            end
          end
          @remaining_retries -= 1
        end
        #After several retries, some nodes may still be in an incorrect state
        if (not @nodes_ko.empty?) && (not @config.exec_specific.breakpointed) then
          #Maybe some other instances are defined
          if not @queue_manager.replay_macro_step_with_next_instance(get_macro_step_name, @cluster, @nodes_ko)
            @queue_manager.add_to_bad_nodes_set(@nodes_ko)
            @queue_manager.decrement_active_threads
          end
        else
          @queue_manager.decrement_active_threads
        end
        finalize()
      }
      return tid
    end
  end

  class BroadcastEnvBittorrent < BroadcastEnv
    # Main of the BroadcastEnvBittorrent instance
    #
    # Arguments
    # * nothing
    # Output
    # * return a thread id
    def run
      tid = Thread.new {
        if @config.exec_specific.breakpointed
          @queue_manager.next_macro_step(get_macro_step_name, @nodes)
        else
          @nodes.duplicate_and_free(@nodes_ko)
        end
        while (@remaining_retries > 0) && (not @nodes_ko.empty?) && (not @config.exec_specific.breakpointed)
          instance_node_set = Nodes::NodeSet.new
          @nodes_ko.duplicate(instance_node_set)
          instance_thread = Thread.new {
            @logger.increment("retry_step2", @nodes_ko)
            @nodes_ko.duplicate_and_free(@nodes_ok)
            @output.verbosel(1, "Performing a BroadcastEnvBittorrent step on the nodes: #{@nodes_ok.to_s_fold}")
            result = true
            #Here are the micro steps 
            result = result && @step.mount_tmp_part #we need /tmp to store the tarball
            result = result && @step.send_environment("bittorrent")
            result = result && @step.manage_admin_post_install("tree")
            result = result && @step.manage_user_post_install("tree")
            result = result && @step.send_key("tree")
            result = result && @step.install_bootloader
            #End of micro steps
          }
          @instances.push(instance_thread)
          if not @step.timeout?(@timeout, instance_thread, get_macro_step_name, instance_node_set) then
            if not @nodes_ok.empty? then
              @logger.set("step2_duration", Time.now.to_i - @start, @nodes_ok)
              @nodes_ok.duplicate_and_free(instance_node_set)
               @queue_manager.next_macro_step(get_macro_step_name, instance_node_set)
             end
          end
          @remaining_retries -= 1
        end
        #After several retries, some nodes may still be in an incorrect state
        if (not @nodes_ko.empty?) && (not @config.exec_specific.breakpointed) then
          #Maybe some other instances are defined
          if not @queue_manager.replay_macro_step_with_next_instance(get_macro_step_name, @cluster, @nodes_ko)
            @queue_manager.add_to_bad_nodes_set(@nodes_ko)
            @queue_manager.decrement_active_threads
          end
        else
          @queue_manager.decrement_active_threads
        end
        finalize()
      }
      return tid
    end
  end

  class BroadcastEnvDummy < BroadcastEnv
    # Main of the BroadcastEnvDummy instance
    #
    # Arguments
    # * nothing
    # Output
    # * return a thread id
    def run
      tid = Thread.new {
        @queue_manager.next_macro_step(get_macro_step_name, @nodes)
        @queue_manager.decrement_active_threads
        finalize()
      }
      return tid
    end
  end
end
