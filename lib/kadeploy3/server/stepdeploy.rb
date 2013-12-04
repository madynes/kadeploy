module Kadeploy

module Macrostep

########################
### SetDeploymentEnv ###
########################

  class DeploySetDeploymentEnv < Deploy
    def load_config()
      super()
    end
  end

  class DeploySetDeploymentEnvUntrusted < DeploySetDeploymentEnv
    def steps()
      [
        [ :switch_pxe, "prod_to_deploy_env", "" ],
        [ :set_vlan, "DEFAULT" ],
        [ :reboot, "soft" ],
        [ :wait_reboot ],
        [ :send_key_in_deploy_env, :tree ],
        [ :create_partition_table ],
        [ :format_deploy_part ],
        [ :mount_deploy_part ],
        [ :format_tmp_part ],
        [ :format_swap_part ],
      ]
    end
  end

  class DeploySetDeploymentEnvKexec < DeploySetDeploymentEnv
    def steps()
      [
        [ :set_vlan, "DEFAULT" ],
        [ :send_deployment_kernel, :tree ],
        [ :sync ],
        [ :kexec,
          'linux',
          context[:cluster].kexec_repository,
          File.basename(context[:cluster].deploy_kernel),
          File.basename(context[:cluster].deploy_initrd),
          context[:cluster].deploy_kernel_args
        ],
        [ :wait_reboot, "kexec" ],
        [ :send_key_in_deploy_env, :tree ],
        [ :create_partition_table ],
        [ :format_deploy_part ],
        [ :mount_deploy_part ],
        [ :format_tmp_part ],
        [ :format_swap_part ],
      ]
    end
  end

  class DeploySetDeploymentEnvUntrustedCustomPreInstall < DeploySetDeploymentEnv
    def steps()
      [
        [ :switch_pxe, "prod_to_deploy_env" ],
        [ :set_vlan, "DEFAULT" ],
        [ :reboot, "soft" ],
        [ :wait_reboot ],
        [ :send_key_in_deploy_env, :tree ],
        [ :manage_admin_pre_install, :tree ],
      ]
    end
  end

  class DeploySetDeploymentEnvProd < DeploySetDeploymentEnv
    def steps()
      [
        [ :check_nodes, "prod_env_booted" ],
        [ :format_deploy_part ],
        [ :mount_deploy_part ],
        [ :format_tmp_part ],
      ]
    end
  end

  class DeploySetDeploymentEnvNfsroot < DeploySetDeploymentEnv
    def steps()
      [
        [ :switch_pxe, "prod_to_nfsroot_env" ],
        [ :set_vlan, "DEFAULT" ],
        [ :reboot, "soft" ],
        [ :wait_reboot ],
        [ :send_key_in_deploy_env, :tree ],
        [ :create_partition_table ],
        [ :format_deploy_part ],
        [ :mount_deploy_part ],
        [ :format_tmp_part ],
        [ :format_swap_part ],
      ]
    end
  end

  class DeploySetDeploymentEnvDummy < DeploySetDeploymentEnv
    def steps()
      [
        [ :dummy ],
        [ :dummy ],
      ]
    end
  end


####################
### BroadcastEnv ###
####################

  class DeployBroadcastEnv < Deploy
    def load_config()
      super()
    end
  end

  class DeployBroadcastEnvChain < DeployBroadcastEnv
    def steps()
      [
        [ :send_environment, :chain ],
        [ :decompress_environment, :tree ],
        [ :manage_admin_post_install, :tree ],
        [ :manage_user_post_install, :tree ],
        [ :check_kernel_files ],
        [ :send_key, :tree ],
        [ :install_bootloader ],
        [ :sync ],
      ]
    end
  end

  class DeployBroadcastEnvKascade < DeployBroadcastEnv
    def steps()
      [
        [ :send_environment, :kascade ],
        [ :decompress_environment, :tree ],
        [ :mount_deploy_part ],
        [ :manage_admin_post_install, :tree ],
        [ :manage_user_post_install, :tree ],
        [ :check_kernel_files ],
        [ :send_key, :tree ],
        [ :install_bootloader ],
        [ :sync ],
      ]
    end
  end

  class DeployBroadcastEnvKastafior < DeployBroadcastEnv
    def steps()
      [
        [ :send_environment, :kastafior ],
        [ :decompress_environment, :tree ],
        [ :mount_deploy_part ],
        [ :manage_admin_post_install, :tree ],
        [ :manage_user_post_install, :tree ],
        [ :check_kernel_files ],
        [ :send_key, :tree ],
        [ :install_bootloader ],
        [ :sync ],
      ]
    end
  end

  class DeployBroadcastEnvTree < DeployBroadcastEnv
    def steps()
      [
        [ :send_environment, :tree ],
        [ :decompress_environment, :tree ],
        [ :manage_admin_post_install, :tree ],
        [ :manage_user_post_install, :tree ],
        [ :check_kernel_files ],
        [ :send_key, :tree ],
        [ :install_bootloader ],
        [ :sync ],
      ]
    end
  end

  class DeployBroadcastEnvBittorrent < DeployBroadcastEnv
    def steps()
      [
        [ :mount_tmp_part ], #we need /tmp to store the tarball
        [ :send_environment, :bittorrent ],
        [ :decompress_environment, :tree ],
        [ :manage_admin_post_install, :tree ],
        [ :manage_user_post_install, :tree ],
        [ :check_kernel_files ],
        [ :send_key, :tree ],
        [ :install_bootloader ],
        [ :sync ],
      ]
    end
  end

  class DeployBroadcastEnvCustom < DeployBroadcastEnv
    def steps()
      [
        [ :send_environment, :custom ],
        [ :decompress_environment, :tree ],
        [ :manage_admin_post_install, :tree ],
        [ :manage_user_post_install, :tree ],
        [ :check_kernel_files ],
        [ :send_key, :tree ],
        [ :install_bootloader ],
        [ :sync ],
      ]
    end
  end

  class DeployBroadcastEnvDummy < DeployBroadcastEnv
    def steps()
      [
        [ :dummy ],
        [ :dummy ],
      ]
    end
  end


##################
### BootNewEnv ###
##################

  class DeployBootNewEnv < Deploy
    def load_config()
      super()
    end
  end

  class DeployBootNewEnvKexec < DeployBootNewEnv
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
