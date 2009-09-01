# Kadeploy 3.0
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008, 2009
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

#Kadelpoy libs
require 'debug'

module BootNewEnvironment
  class BootNewEnvFactory
    # Factory for the methods to boot a new environment
    #
    # Arguments
    # * kind: specifies the method to use (BootNewEnvKexec, BootNewEnvClassical, BootNewEnvDummy)
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
    # * returns a BootNewEnv instance (BootNewEnvKexec, BootNewEnvPivotRoot, BootNewEnvClassical, BootNewEnvDummy)
    # * raises an exception if an invalid kind of instance is given
    def BootNewEnvFactory.create(kind, max_retries, timeout, cluster, nodes, queue_manager, reboot_window, nodes_check_window, output, logger)
      case kind
      when "BootNewEnvKexec"
        return BootNewEnvKexec.new(max_retries, timeout, cluster, nodes, queue_manager, reboot_window, nodes_check_window, output, logger)
      when "BootNewEnvPivotRoot"
        return BootNewEnvPivotRoot.new(max_retries, timeout, cluster, nodes, queue_manager, reboot_window, nodes_check_window, output, logger) 
      when "BootNewEnvClassical"
        return BootNewEnvClassical.new(max_retries, timeout, cluster, nodes, queue_manager, reboot_window, nodes_check_window, output, logger)
      when "BootNewEnvHardReboot"
        return BootNewEnvHardReboot.new(max_retries, timeout, cluster, nodes, queue_manager, reboot_window, nodes_check_window, output, logger)        
      when "BootNewEnvDummy"
        return BootNewEnvDummy.new(max_retries, timeout, cluster, nodes, queue_manager, reboot_window, nodes_check_window, output, logger)
      else
        raise "Invalid kind of step value for the new environment boot step"
      end
    end
  end

  class BootNewEnv
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

    # Constructor of BootNewEnv
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
      @logger.set("step3", get_instance_name, @nodes)
      @logger.set("timeout_step3", @timeout, @nodes)
      @instances = Array.new
      @start = Time.now.to_i
      @step = MicroStepsLibrary::MicroSteps.new(@nodes_ok, @nodes_ko, @reboot_window, @nodes_check_window, @config, cluster, output, get_instance_name)
    end
    
    # Kill all the running threads
    #
    # Arguments
    # * nothing
    # Output
    # * nothing
    def kill
      @instances.each { |tid|
        Thread.kill(tid)
      }
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

  class BootNewEnvKexec < BootNewEnv
    # Main of the BootNewEnvKexec instance
    #
    # Arguments
    # * nothing
    # Output
    # * return a thread id
    def run
      tid = Thread.new {
        @queue_manager.next_macro_step(get_macro_step_name, @nodes) if @config.exec_specific.breakpointed
        @nodes.duplicate_and_free(@nodes_ko)
        while (@remaining_retries > 0) && (not @nodes_ko.empty?) && (not @config.exec_specific.breakpointed)
          instance_node_set = Nodes::NodeSet.new
          @nodes_ko.duplicate(instance_node_set)
          instance_thread = Thread.new {
            @logger.increment("retry_step3", @nodes_ko)
            @nodes_ko.duplicate_and_free(@nodes_ok)
            @output.verbosel(1, "Performing a BootNewEnvKexec step on the nodes: #{@nodes_ok.to_s}")
            result = true
            #Here are the micro steps
            result = result && @step.reboot("kexec")
            result = result && @step.wait_reboot([@config.common.ssh_port],[@config.common.test_deploy_env_port])
            #End of micro steps
          }
          @instances.push(instance_thread)
          if not @step.timeout?(@timeout, instance_thread, get_macro_step_name, instance_node_set) then
            if not @nodes_ok.empty? then
              @logger.set("step3_duration", Time.now.to_i - @start, @nodes_ok)
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
      }
      return tid
    end
  end

  class BootNewEnvPivotRoot < BootNewEnv
    # Main of the BootNewEnvPivotRoot instance
    #
    # Arguments
    # * nothing
    # Output
    # * return a thread id
    def run
      tid = Thread.new {
        @queue_manager.next_macro_step(get_macro_step_name, @nodes) if @config.exec_specific.breakpointed
        @nodes.duplicate_and_free(@nodes_ko)
        while (@remaining_retries > 0) && (not @nodes_ko.empty?) && (not @config.exec_specific.breakpointed)
          instance_node_set = Nodes::NodeSet.new
          @nodes_ko.duplicate(instance_node_set)
          instance_thread = Thread.new {
            @logger.increment("retry_step3", @nodes_ko)
            @nodes_ko.duplicate_and_free(@nodes_ok)
            @output.verbosel(1, "Performing a BootNewEnvPivotRoot step on the nodes: #{@nodes_ok.to_s}")
            result = true
            #Here are the micro steps
            @output.verbosel(0, "BootNewEnvPivotRoot is not yet implemented")
            #End of micro steps
          }
          @instances.push(instance_thread)
          if not @step.timeout?(@timeout, instance_thread, get_macro_step_name, instance_node_set) then
            if not @nodes_ok.empty? then
              @logger.set("step3_duration", Time.now.to_i - @start, @nodes_ok)
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
      }
      return tid
    end
  end

  class BootNewEnvClassical < BootNewEnv
    # Main of the BootNewEnvClassical instance
    #
    # Arguments
    # * nothing
    # Output
    # * return a thread id
    def run
      tid = Thread.new {
        @queue_manager.next_macro_step(get_macro_step_name, @nodes) if @config.exec_specific.breakpointed
        @nodes.duplicate_and_free(@nodes_ko)
        while (@remaining_retries > 0) && (not @nodes_ko.empty?) && (not @config.exec_specific.breakpointed)
          instance_node_set = Nodes::NodeSet.new
          @nodes_ko.duplicate(instance_node_set)
          instance_thread = Thread.new {
            use_rsh_for_reboot = (@config.common.taktuk_connector == @config.common.taktuk_rsh_connector)
            @logger.increment("retry_step3", @nodes_ko)
            @nodes_ko.duplicate_and_free(@nodes_ok)
            @output.verbosel(1, "Performing a BootNewEnvClassical step on the nodes: #{@nodes_ok.to_s}")
            result = true
            #Here are the micro steps 
            result = result && @step.umount_deploy_part
            result = result && @step.reboot_from_deploy_env
            result = result && @step.wait_reboot([@config.common.ssh_port],[@config.common.test_deploy_env_port])
            #End of micro steps
          }
          @instances.push(instance_thread)
          if not @step.timeout?(@timeout, instance_thread, get_macro_step_name, instance_node_set) then
            if not @nodes_ok.empty? then
              @logger.set("step3_duration", Time.now.to_i - @start, @nodes_ok)
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
      }
      return tid
    end
  end

  class BootNewEnvHardReboot < BootNewEnv
    # Main of the BootNewEnvHardReboot instance
    #
    # Arguments
    # * nothing
    # Output
    # * return a thread id
    def run
      tid = Thread.new {
        @queue_manager.next_macro_step(get_macro_step_name, @nodes) if @config.exec_specific.breakpointed
        @nodes.duplicate_and_free(@nodes_ko)
        while (@remaining_retries > 0) && (not @nodes_ko.empty?) && (not @config.exec_specific.breakpointed)
          instance_node_set = Nodes::NodeSet.new
          @nodes_ko.duplicate(instance_node_set)
          instance_thread = Thread.new {
            use_rsh_for_reboot = (@config.common.taktuk_connector == @config.common.taktuk_rsh_connector)
            @logger.increment("retry_step3", @nodes_ko)
            @nodes_ko.duplicate_and_free(@nodes_ok)
            @output.verbosel(1, "Performing a BootNewEnvHardReboot step on the nodes: #{@nodes_ok.to_s}")
            result = true
            #Here are the micro steps 
            result = result && @step.reboot("hard")
            result = result && @step.wait_reboot([@config.common.ssh_port],[@config.common.test_deploy_env_port])
            #End of micro steps
          }
          @instances.push(instance_thread)
          if not @step.timeout?(@timeout, instance_thread, get_macro_step_name, instance_node_set) then
            if not @nodes_ok.empty? then
              @logger.set("step3_duration", Time.now.to_i - @start, @nodes_ok)
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
      }
      return tid
    end
  end

  class BootNewEnvDummy < BootNewEnv
    # Main of the BootNewEnvDummy instance
    #
    # Arguments
    # * nothing
    # Output
    # * return a thread id
    def run
      @config.common.taktuk_connector = @config.common.taktuk_ssh_connector
      tid = Thread.new {
        @queue_manager.next_macro_step(get_macro_step_name, @nodes)
        @queue_manager.decrement_active_threads
      }
      return tid
    end
  end
end
