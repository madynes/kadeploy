# Kadeploy 3.1
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2010
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

#Kadelpoy libs
require 'debug'

module SetDeploymentEnvironnment

  class SetDeploymentEnvFactory
    # Factory for the methods to set a deployment environment
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
    # * returns a SetDeploymentEnv instance (SetDeploymentEnvUntrusted, SetDeploymentEnvUntrustedCustomPreInstall, SetDeploymentEnvNfsroot, SetDeploymentEnvProd, SetDeploymentEnvDummy)
    # * raises an exception if an invalid kind of instance is given
    def SetDeploymentEnvFactory.create(kind, max_retries, timeout, cluster, nodes, queue_manager, reboot_window, nodes_check_window, output, logger)
      begin
        klass = SetDeploymentEnvironnment::class_eval(kind)
      rescue NameError
        raise "Invalid kind of step value for the environment deployment step"
      end
      return klass.new(max_retries, timeout, cluster, nodes, queue_manager, reboot_window, nodes_check_window, output, logger)
    end
  end

  class SetDeploymentEnv
    @remaining_retries = 0
    @timeout = 0
    @queue_manager = nil
    @reboot_window = nil
    @nodes_check_window = nil
    @output = nil
    @cluster = nil
    @nodes = nil
    @nodes_ok = nil
    @nodes_ko = nil
    @step = nil
    @config = nil
    @logger = nil
    @start = nil
    @instances = nil

    # Constructor ofSetDeploymentEnv
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
      @logger.set("step1", get_instance_name, @nodes)
      @logger.set("timeout_step1", @timeout, @nodes)
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

  class SetDeploymentEnvUntrusted < SetDeploymentEnv
    # Main of the SetDeploymentEnvUntrusted instance
    #
    # Arguments
    # * nothing
    # Output
    # * return a thread id
    def run
      first_attempt = true
      tid = Thread.new {
        @queue_manager.next_macro_step(get_macro_step_name, @nodes) if @config.exec_specific.breakpointed
        @nodes.duplicate_and_free(@nodes_ko)
        while (@remaining_retries > 0) && (not @nodes_ko.empty?) && (not @config.exec_specific.breakpointed)
          instance_node_set = Nodes::NodeSet.new
          @nodes_ko.duplicate(instance_node_set)
          instance_thread = Thread.new {
            @logger.increment("retry_step1", @nodes_ko)
            @nodes_ko.duplicate_and_free(@nodes_ok)
            @output.verbosel(1, "Performing a SetDeploymentEnvUntrusted step on the nodes: #{@nodes_ok.to_s_fold}")
            result = true
            if (@config.exec_specific.reboot_classical_timeout == nil) then
              timeout = @config.cluster_specific[@cluster].timeout_reboot_classical
            else
              timeout = @config.exec_specific.reboot_classical_timeout
            end
            #Here are the micro steps
            result = result && @step.switch_pxe("prod_to_deploy_env", "")
            result = result && @step.reboot("soft", first_attempt)
            result = result && @step.wait_reboot([@config.common.ssh_port,@config.common.test_deploy_env_port],[],
                                                 timeout)
            result = result && @step.send_key_in_deploy_env("tree")
            result = result && @step.create_partition_table("untrusted_env")
            result = result && @step.format_deploy_part
            result = result && @step.mount_deploy_part
            result = result && @step.format_tmp_part
            result = result && @step.format_swap_part
            #End of micro steps
          }
          @instances.push(instance_thread)
          if not @step.timeout?(@timeout, instance_thread, get_macro_step_name, instance_node_set) then
            if not @nodes_ok.empty? then
              @logger.set("step1_duration", Time.now.to_i - @start, @nodes_ok)
              @nodes_ok.duplicate_and_free(instance_node_set)
              @queue_manager.next_macro_step(get_macro_step_name, instance_node_set)
            end
          end
          @remaining_retries -= 1
          first_attempt = false
        end
        #After several retries, some nodes may still be in an incorrect state
        if (not @nodes_ko.empty?) && (not @config.exec_specific.breakpointed) then
          #Maybe some other instances are defined
          if not @queue_manager.replay_macro_step_with_next_instance(get_macro_step_name, @cluster, @nodes_ko) then
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

  class SetDeploymentEnvUntrustedCustomPreInstall < SetDeploymentEnv
    # Main of the SetDeploymentEnvUntrustedPreInstall instance
    #
    # Arguments
    # * nothing
    # Output
    # * return a thread id
    def run
      first_attempt = true
      tid = Thread.new {
        @queue_manager.next_macro_step(get_macro_step_name, @nodes) if @config.exec_specific.breakpointed
        @nodes.duplicate_and_free(@nodes_ko)
        while (@remaining_retries > 0) && (not @nodes_ko.empty?) && (not @config.exec_specific.breakpointed)
          instance_node_set = Nodes::NodeSet.new
          @nodes_ko.duplicate(instance_node_set)
          instance_thread = Thread.new {
            @logger.increment("retry_step1", @nodes_ko)
            @nodes_ko.duplicate_and_free(@nodes_ok)
            @output.verbosel(1, "Performing a SetDeploymentEnvUntrustedCustomPreInstall step on the nodes: #{@nodes_ok.to_s_fold}")
            result = true
            if (@config.exec_specific.reboot_classical_timeout == nil) then
              timeout = @config.cluster_specific[@cluster].timeout_reboot_classical
            else
              timeout = @config.exec_specific.reboot_classical_timeout
            end
            #Here are the micro steps
            result = result && @step.switch_pxe("prod_to_deploy_env")
            result = result && @step.reboot("soft", first_attempt)
            result = result && @step.wait_reboot([@config.common.ssh_port,@config.common.test_deploy_env_port],[],
                                                 timeout)
            result = result && @step.send_key_in_deploy_env("tree")
            result = result && @step.manage_admin_pre_install("tree")
            #End of micro steps
          }
          @instances.push(instance_thread)
          if not @step.timeout?(@timeout, instance_thread, get_macro_step_name, instance_node_set) then
            if not @nodes_ok.empty? then
              @logger.set("step1_duration", Time.now.to_i - @start, @nodes_ok)
              @nodes_ok.duplicate_and_free(instance_node_set)
              @queue_manager.next_macro_step(get_macro_step_name, instance_node_set)
            end
          end
          @remaining_retries -= 1
          first_attempt = false
        end
        #After several retries, some nodes may still be in an incorrect state
        if (not @nodes_ko.empty?) && (not @config.exec_specific.breakpointed) then
          #Maybe some other instances are defined
          if not @queue_manager.replay_macro_step_with_next_instance(get_macro_step_name, @cluster, @nodes_ko) then
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

  class SetDeploymentEnvProd < SetDeploymentEnv
    # Main of the SetDeploymentEnvProd instance
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
            @logger.increment("retry_step1", @nodes_ko)
            @nodes_ko.duplicate_and_free(@nodes_ok)
            @output.verbosel(1, "Performing a SetDeploymentEnvProd step on the nodes: #{@nodes_ok.to_s_fold}")
            result = true
            #Here are the micro steps
            result = result && @step.check_nodes("prod_env_booted")
            result = result && @step.create_partition_table("prod_env")
            result = result && @step.format_deploy_part
            result = result && @step.mount_deploy_part
            result = result && @step.format_tmp_part
            #End of micro steps
          }
          @instances.push(instance_thread)
          if not @step.timeout?(@timeout, instance_thread, get_macro_step_name, instance_node_set) then
            if not @nodes_ok.empty? then
              @logger.set("step1_duration", Time.now.to_i - @start, @nodes_ok)
              @nodes_ok.duplicate_and_free(instance_node_set)
              @queue_manager.next_macro_step(get_macro_step_name, instance_node_set)
            end
          end
          @remaining_retries -= 1
        end
        #After several retries, some nodes may still be in an incorrect state
        if (not @nodes_ko.empty?) && (not @config.exec_specific.breakpointed) then
          #Maybe some other instances are defined
          if not @queue_manager.replay_macro_step_with_next_instance(get_macro_step_name, @cluster, @nodes_ko) then
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

  
  class SetDeploymentEnvNfsroot < SetDeploymentEnv
    # Main of the SetDeploymentEnvNfsroot instance
    #
    # Arguments
    # * nothing
    # Output
    # * return a thread id
    def run
      first_attempt = true
      tid = Thread.new {
        @queue_manager.next_macro_step(get_macro_step_name, @nodes) if @config.exec_specific.breakpointed
        @nodes.duplicate_and_free(@nodes_ko)
        while (@remaining_retries > 0) && (not @nodes_ko.empty?) && (not @config.exec_specific.breakpointed)
          instance_node_set = Nodes::NodeSet.new
          @nodes_ko.duplicate(instance_node_set)
          instance_thread = Thread.new {
            @logger.increment("retry_step1", @nodes_ko)
            @nodes_ko.duplicate_and_free(@nodes_ok)
            @output.verbosel(1, "Performing a SetDeploymentEnvNfsroot step on the nodes: #{@nodes_ok.to_s_fold}")
            result = true
            if (@config.exec_specific.reboot_classical_timeout == nil) then
              timeout = @config.cluster_specific[@cluster].timeout_reboot_classical
            else
              timeout = @config.exec_specific.reboot_classical_timeout
            end
            #Here are the micro steps
            result = result && @step.switch_pxe("prod_to_nfsroot_env")            
            result = result && @step.reboot("soft", first_attempt)
            result = result && @step.wait_reboot([@config.common.ssh_port,@config.common.test_deploy_env_port],[],
                                                 timeout)
            result = result && @step.send_key_in_deploy_env("tree")
            result = result && @step.create_partition_table("untrusted_env")
            result = result && @step.format_deploy_part
            result = result && @step.mount_deploy_part
            result = result && @step.format_tmp_part
            result = result && @step.format_swap_part
            #End of micro steps
          }
          @instances.push(instance_thread)
          if not @step.timeout?(@timeout, instance_thread, get_macro_step_name, instance_node_set) then
            if not @nodes_ok.empty? then
              @logger.set("step1_duration", Time.now.to_i - @start, @nodes_ok)
              @nodes_ok.duplicate_and_free(instance_node_set)
              @queue_manager.next_macro_step(get_macro_step_name, instance_node_set)
            end
          end
          @remaining_retries -= 1
          first_attempt = false
        end
        #After several retries, some nodes may still be in an incorrect state
        if (not @nodes_ko.empty?) && (not @config.exec_specific.breakpointed) then
          #Maybe some other instances are defined
          if not @queue_manager.replay_macro_step_with_next_instance(get_macro_step_name, @cluster, @nodes_ko) then
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

  class SetDeploymentEnvDummy < SetDeploymentEnv
    # Main of the SetDeploymentEnvDummy instance
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
