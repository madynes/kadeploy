require 'debug'
require 'macrostep'

module Kadeploy

module Macrostep
  class DeployBootNewEnv < Deploy
    def load_config()
      super()
    end
  end

  class DeployBootNewEnvKexec < DeployBootNewEnv
    # Get the name of the deployment partition
    #
    # Arguments
    # * nothing
    # Output
    # * return the name of the deployment partition
    def get_deploy_part_str
      b=nil
      if context[:execution].block_device != ""
        b = context[:execution].block_device
      else
        b = context[:cluster].block_device
      end

      p=nil
      if context[:execution].deploy_part.nil?
        p = ''
      elsif context[:execution].deploy_part != ""
        p = context[:execution].deploy_part
      else
        p = context[:cluster].deploy_part
      end

      b + p
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
      if !context[:execution].environment.kernel_params.nil? and !context[:execution].environment.kernel_params.empty?
        kernel_params = context[:execution].environment.kernel_params
      #Otherwise we eventually check in the cluster specific configuration
      elsif (context[:cluster].kernel_params != nil) then
        kernel_params = context[:cluster].kernel_params
      else
        kernel_params = ""
      end

      unless kernel_params.include?('root=')
        kernel_params = "root=#{get_deploy_part_str()} #{kernel_params}"
      end

      return kernel_params
    end

    def steps()
      [
        [ :switch_pxe, "deploy_to_deployed_env" ],
        [ :umount_deploy_part ],
        [ :mount_deploy_part ],
        [ :kexec,
          context[:execution].environment.environment_kind,
          context[:common].environment_extraction_dir,
          context[:execution].environment.kernel,
          context[:execution].environment.initrd,
          get_kernel_params()
        ],
        [ :set_vlan ],
        [ :wait_reboot, "kexec", "user", true ],
      ]
    end
  end

  class DeployBootNewEnvPivotRoot < DeployBootNewEnv
    def start!
      debug(0, "#{self.class.name} is not yet implemented")
      kill()
      return false
    end
  end

  class DeployBootNewEnvClassical < DeployBootNewEnv
    def steps()
      [
        [ :switch_pxe, "deploy_to_deployed_env" ],
        [ :umount_deploy_part ],
        [ :reboot_from_deploy_env ],
        [ :set_vlan ],
        [ :wait_reboot, "classical", "user", true ],
      ]
    end
  end

  class DeployBootNewEnvHardReboot < DeployBootNewEnv
    def steps()
      [
        [ :switch_pxe, "deploy_to_deployed_env" ],
        [ :reboot, "hard" ],
        [ :set_vlan ],
        [ :wait_reboot, "classical", "user", true ],
      ]
    end
  end

  class DeployBootNewEnvDummy < DeployBootNewEnv
    def steps()
      [
        [ :dummy ],
        [ :dummy ],
      ]
    end
  end
end

end
