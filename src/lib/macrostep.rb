# Kadeploy 3.1
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2011
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

#Kadelpoy libs
require 'debug'

module MacroSteps
  def self.typenames()
    [
      'SetDeploymentEnv',
      'BroadcastEnv',
      'BootNewEnv',
    ]
  end

  class MacroStepFactory
    # Factory for the macrosteps methods
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
    # * returns a MacroStep instance
    # * raises an exception if an invalid kind of instance is given
    def self.create(kind, max_retries, timeout, cluster, nodes, queue_manager, reboot_window, nodes_check_window, output, logger)
      begin
        klass = self.class_eval(kind)
      rescue NameError
        raise "Invalid kind of step value for the new environment boot step"
      end
      return klass.new(max_retries, timeout, cluster, nodes, queue_manager, reboot_window, nodes_check_window, output, logger)
    end
  end

  class MacroStep
    @remaining_retries = 0
    @timeout = 0
    @queue_manager = nil
    @config = nil
    @cluster_config = nil
    @reboot_window = nil
    @nodes_check_window = nil
    @output = nil
    @nodes = nil
    @nodes_ok = nil
    @nodes_ko = nil
    @curstep = nil
    @start = nil
    @loglevel = nil
    @currentretry = nil

    # Constructor of MacroStep
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
    def initialize(max_retries, timeout, cluster, nodes, queue_manager, reboot_window, nodes_check_window, output, logger, loglevel=0)
      @remaining_retries = max_retries
      @timeout = timeout
      @nodes = nodes
      @queue_manager = queue_manager
      @config = @queue_manager.config
      @cluster_config = @config.cluster_specific[cluster]
      @reboot_window = reboot_window
      @nodes_check_window = nodes_check_window
      @output = output
      @nodes_ok = Nodes::NodeSet.new(@nodes.id)
      @nodes_ko = Nodes::NodeSet.new(@nodes.id)
      @loglevel = loglevel
      @logger = logger
      @logger.set("step#{@loglevel}", get_instance_name, @nodes)
      @logger.set("timeout_step#{@loglevel}", @timeout, @nodes)
      @start = Time.now.to_i
      @currentretry = 0
      @curstep = nil
    end

    def finalize
      @queue_manager = nil
      @config = nil
      #@cluster_config = nil
      @reboot_window = nil
      @nodes_check_window = nil
      @output = nil
      @nodes_ok = nil
      @nodes_ko = nil
      @logger = nil
      @instances = nil
      @start = nil
      @curstep = nil
    end

    # Kill all the running threads
    #
    # Arguments
    # * nothing
    # Output
    # * nothing
    def kill
      @curstep.kill
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


    # Run the macrostep specific microsteps
    #
    # Arguments
    # * nothing
    # Output
    # * return a thread id
    def microsteps(step)
      raise 'Should be reimplemented'
    end

    def microstep_timeout?(step,instance_node_set)
      start = Time.now.to_i
      while ((step.instance_thread.status != false) && (Time.now.to_i < (start + @timeout)))
        sleep(1)
      end
      if (step.instance_thread.status != false) then
        @output.verbosel(3, "Timeout before the end of the step on cluster #{@cluster_config.name}, let's kill the instance",@nodes_ok)
        kill()
        step.nodes_ok.free
        instance_node_set.set_error_msg("Timeout in the #{get_macro_step_name} step")
        instance_node_set.add_diff_and_free(step.nodes_ko)
        step.nodes_ko.set.each { |node|
          node.state = "KO"
          @config.set_node_state(node.hostname, "", "", "ko")
        }
        return true
      else
        instance_node_set.free()
        step.instance_thread.join
        return false
      end
    end

    # Generic automata that run a macrostep
    #
    # Arguments
    # * nothing
    # Output
    # * return a thread id
    def run
      tid = Thread.new do
        if @config.exec_specific.breakpointed
          @queue_manager.next_macro_step(get_macro_step_name(), @nodes)
        else
          @nodes.duplicate_and_free(@nodes_ko)
        end

        @currentretry = 0
        while (@remaining_retries > 0) && (not @nodes_ko.empty?) && (not @config.exec_specific.breakpointed)

          instance_node_set = Nodes::NodeSet.new
          @nodes_ko.duplicate(instance_node_set)

          @curstep = MicroStepsLibrary::MicroSteps.new(
            @nodes_ok,
            @nodes_ko,
            @reboot_window,
            @nodes_check_window,
            @config,
            @cluster_config,
            @output,
            get_instance_name
          )

          instance_thread = Thread.new do
            @curstep.instance_thread = Thread.current

            @logger.increment("retry_step#{@loglevel}", @nodes_ko)
            @nodes_ko.duplicate_and_free(@nodes_ok)

            @output.verbosel(
              1,
              "Performing a #{get_instance_name()} step "\
              "on the nodes: #{@nodes_ok.to_s_fold}",
              @nodes_ok
            )

            microsteps(@curstep)
          end


          if not microstep_timeout?(@curstep, instance_node_set) then
            if not @nodes_ok.empty? then
              if not @nodes_ko.empty?
                tmp = @nodes_ok.id
                @config.exec_specific.nodesetid += 1
                @nodes_ok.id = @config.exec_specific.nodesetid

                @config.exec_specific.nodesetid += 1
                @nodes_ko.id = @config.exec_specific.nodesetid

                @output.verbosel(
                  2,
                  "Nodeset(#{tmp}) split into :\n"\
                  "  Nodeset(#{@nodes_ok.id}): #{@nodes_ok.to_s_fold}\n"\
                  "  Nodeset(#{@nodes_ko.id}): #{@nodes_ko.to_s_fold}\n"
                )
              end

              @logger.set(
                "step#{@loglevel}_duration",
                Time.now.to_i - @start,
                @nodes_ok
              )

              @nodes_ok.duplicate_and_free(instance_node_set)
              @queue_manager.next_macro_step(
                get_macro_step_name,
                instance_node_set
              )
            end
          end
          @remaining_retries -= 1
          @currentretry += 1
        end


        #After several retries, some nodes may still be in an incorrect state
        if (not @nodes_ko.empty?) && (not @config.exec_specific.breakpointed) then
          #Maybe some other instances are defined
          if not @queue_manager.replay_macro_step_with_next_instance(get_macro_step_name, @cluster_config.name, @nodes_ko)
            @queue_manager.add_to_bad_nodes_set(@nodes_ko)
            @queue_manager.decrement_active_threads
          end
        else
          @queue_manager.decrement_active_threads
        end

        finalize()
      end

      return tid
    end
  end
end
