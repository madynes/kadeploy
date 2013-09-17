require 'debug'
require 'macrostep'

module Kadeploy

module Macrostep
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
end

end
