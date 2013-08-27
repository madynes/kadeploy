require 'debug'
require 'macrostep'

module Kadeploy

module Macrostep
  class KadeploySetDeploymentEnv < Kadeploy
    def load_config()
      super()
    end
  end

  class KadeploySetDeploymentEnvUntrusted < KadeploySetDeploymentEnv
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

  class KadeploySetDeploymentEnvKexec < KadeploySetDeploymentEnv
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

  class KadeploySetDeploymentEnvUntrustedCustomPreInstall < KadeploySetDeploymentEnv
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

  class KadeploySetDeploymentEnvProd < KadeploySetDeploymentEnv
    def steps()
      [
        [ :check_nodes, "prod_env_booted" ],
        [ :format_deploy_part ],
        [ :mount_deploy_part ],
        [ :format_tmp_part ],
      ]
    end
  end

  class KadeploySetDeploymentEnvNfsroot < KadeploySetDeploymentEnv
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

  class KadeploySetDeploymentEnvDummy < KadeploySetDeploymentEnv
    def steps()
      [
        [ :dummy ],
        [ :dummy ],
      ]
    end
  end
end

end
