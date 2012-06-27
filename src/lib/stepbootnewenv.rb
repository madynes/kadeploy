# Kadeploy 3.1
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2011
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

#Kadelpoy libs
require 'debug'
require 'macrostep'

module MacroSteps
  class BootNewEnv < MacroStep
    def initialize(max_retries, timeout, cluster, nodes, queue_manager, reboot_window, nodes_check_window, output, logger)

      super(
        max_retries,
        timeout,
        cluster,
        nodes,
        queue_manager,
        reboot_window,
        nodes_check_window,
        output,
        logger,
        3
      )

    end
  end

  class BootNewEnvKexec < BootNewEnv
    # Get the name of the deployment partition
    #
    # Arguments
    # * nothing
    # Output
    # * return the name of the deployment partition
    def get_deploy_part_str
      if (@config.exec_specific.deploy_part != "") then
        if (@config.exec_specific.block_device != "") then
          return @config.exec_specific.block_device + @config.exec_specific.deploy_part
        else
          return @config.cluster_specific[@cluster].block_device + @config.exec_specific.deploy_part
        end
      else
        return @config.cluster_specific[@cluster].block_device + @config.cluster_specific[@cluster].deploy_part
      end
    end

    # Get the kernel parameters
    #
    # Arguments
    # * nothing
    # Output
    # * return the kernel parameters
    def get_kernel_params
      kernel_params = String.new
      #We first check if the kernel parameters are defined in the environment
      if (@config.exec_specific.environment.kernel_params != nil) then
        kernel_params = @config.exec_specific.environment.kernel_params
      #Otherwise we eventually check in the cluster specific configuration
      elsif (@config.cluster_specific[@cluster].kernel_params != nil) then
        kernel_params = @config.cluster_specific[@cluster].kernel_params
      else
        kernel_params = ""
      end

      unless kernel_params.include?('root=')
        kernel_params = "root=#{get_deploy_part_str()} #{kernel_params}"
      end

      return kernel_params
    end

    def microsteps()
      ret = true
      ret = ret && @step.switch_pxe("deploy_to_deployed_env")
      ret = ret && @step.umount_deploy_part
      ret = ret && @step.mount_deploy_part
      ret = ret && @step.kexec(
        @config.exec_specific.environment.environment_kind,
        @config.common.environment_extraction_dir,
        @config.exec_specific.environment.kernel,
        @config.exec_specific.environment.initrd,
        get_kernel_params()
      )
      ret = ret && @step.set_vlan
      ret = ret && @step.wait_reboot("kexec","user",true)
      return ret
    end
  end

  class BootNewEnvPivotRoot < BootNewEnv
    def microsteps()
      @output.verbosel(0, "BootNewEnvPivotRoot is not yet implemented")
      return false
    end
  end

  class BootNewEnvClassical < BootNewEnv
    def microsteps()
      ret = true
      ret = ret && @step.switch_pxe("deploy_to_deployed_env")
      ret = ret && @step.umount_deploy_part
      ret = ret && @step.reboot_from_deploy_env
      ret = ret && @step.set_vlan
      ret = ret && @step.wait_reboot("classical","user",true)
      return ret
    end
  end

  class BootNewEnvHardReboot < BootNewEnv
    def microsteps()
      ret = true
      ret = ret && @step.switch_pxe("deploy_to_deployed_env")
      ret = ret && @step.reboot("hard", false)
      ret = ret && @step.set_vlan
      ret = ret && @step.wait_reboot("classical","user",true)
      return ret
    end
  end

  class BootNewEnvDummy < BootNewEnv
    def run
      tid = Thread.new {
        @queue_manager.next_macro_step(get_macro_step_name, @nodes)
        @queue_manager.decrement_active_threads
        finalize()
      }
      return tid
    end

    def microsteps()
      return true
    end
  end
end
