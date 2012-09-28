# Kadeploy 3.1
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2011
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

#Kadelpoy libs
require 'debug'
require 'macrostep'

#module MacroSteps
  class BootNewEnv < Macrostep
    def load_config()
      super()
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
          return @cluster_config.block_device + @config.exec_specific.deploy_part
        end
      else
        return @cluster_config.block_device + @cluster_config.deploy_part
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
      elsif (@cluster_config.kernel_params != nil) then
        kernel_params = @cluster_config.kernel_params
      else
        kernel_params = ""
      end

      unless kernel_params.include?('root=')
        kernel_params = "root=#{get_deploy_part_str()} #{kernel_params}"
      end

      return kernel_params
    end

    def tasks()
      [
        [ :switch_pxe, "deploy_to_deployed_env" ],
        [ :umount_deploy_part ],
        [ :mount_deploy_part ],
        [ :kexec,
          @config.exec_specific.environment.environment_kind,
          @config.common.environment_extraction_dir,
          @config.exec_specific.environment.kernel,
          @config.exec_specific.environment.initrd,
          get_kernel_params()
        ],
        [ :set_vlan ],
        [ :wait_reboot, "kexec", "user", true ],
      ]
    end
  end

  class BootNewEnvPivotRoot < BootNewEnv
    def start!
      debug(0, "#{self.class.name} is not yet implemented")
      kill()
      return false
    end
  end

  class BootNewEnvClassical < BootNewEnv
    def tasks()
      [
        [ :switch_pxe, "deploy_to_deployed_env" ],
        [ :umount_deploy_part ],
        [ :reboot_from_deploy_env ],
        [ :set_vlan ],
        [ :wait_reboot, "classical", "user", true ],
      ]
    end
  end

  class BootNewEnvHardReboot < BootNewEnv
    def tasks()
      [
        [ :switch_pxe, "deploy_to_deployed_env" ],
        [ :reboot, "hard", false ],
        [ :set_vlan ],
        [ :wait_reboot, "classical", "user", true ],
      ]
    end
  end

  class BootNewEnvDummy < BootNewEnv
    def start()
      true
    end

    def tasks()
      []
    end
  end
end
