# Kadeploy 3.1
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2011
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

#Kadelpoy libs
require 'debug'
require 'macrostep'

#module MacroSteps
  class SetDeploymentEnv < Macrostep
    def load_config()
      super()
    end
  end

  class SetDeploymentEnvUntrusted < SetDeploymentEnv
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

  class SetDeploymentEnvKexec < SetDeploymentEnv
    def steps()
      [
        [ :set_vlan, "DEFAULT" ],
        [ :send_deployment_kernel, :tree ],
        [ :kexec,
          'linux',
          context[:cluster].kexec_repository,
          context[:cluster].deploy_kernel,
          context[:cluster].deploy_initrd,
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

  class SetDeploymentEnvUntrustedCustomPreInstall < SetDeploymentEnv
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

  class SetDeploymentEnvProd < SetDeploymentEnv
    def steps()
      [
        [ :check_nodes, "prod_env_booted" ],
        [ :format_deploy_part ],
        [ :mount_deploy_part ],
        [ :format_tmp_part ],
      ]
    end
  end

  class SetDeploymentEnvNfsroot < SetDeploymentEnv
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

  class SetDeploymentEnvDummy < SetDeploymentEnv
    def start()
      true
    end

    def steps()
      []
    end
  end
#end
