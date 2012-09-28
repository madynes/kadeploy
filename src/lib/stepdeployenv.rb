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
    def tasks()
      [
        [ :switch_pxe, "prod_to_deploy_env", "" ],
        [ :set_vlan, "DEFAULT" ],
        [ :reboot, "soft" ],
        [ :wait_reboot ],
        [ :send_key_in_deploy_env, :tree ],
        [ :create_partition_table, "untrusted_env" ],
        [ :format_deploy_part ],
        [ :mount_deploy_part ],
        [ :format_tmp_part ],
        [ :format_swap_part ],
      ]
    end
  end

  class SetDeploymentEnvKexec < SetDeploymentEnv
    def tasks()
      [
        [ :switch_pxe, "prod_to_deploy_env", "" ],
        [ :set_vlan, "DEFAULT" ],
        [ :create_kexec_repository ],
        [ :send_deployment_kernel, :tree ],
        [ :kexec,
          'linux',
          @cluster_config.kexec_repository,
          @cluster_config.deploy_kernel,
          @cluster_config.deploy_initrd,
          @cluster_config.deploy_kernel_args
        ],
        [ :wait_reboot, "kexec" ],
        [ :send_key_in_deploy_env, :tree ],
        [ :create_partition_table, "untrusted_env" ],
        [ :format_deploy_part ],
        [ :mount_deploy_part ],
        [ :format_tmp_part ],
        [ :format_swap_part ],
      ]
    end
  end

  class SetDeploymentEnvUntrustedCustomPreInstall < SetDeploymentEnv
    def tasks()
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
    def tasks()
      [
        [ :check_nodes, "prod_env_booted" ],
        [ :create_partition_table, "prod_env" ],
        [ :format_deploy_part ],
        [ :mount_deploy_part ],
        [ :format_tmp_part ],
      ]
    end
  end

  class SetDeploymentEnvNfsroot < SetDeploymentEnv
    def tasks()
      [
        [ :switch_pxe, "prod_to_nfsroot_env" ],
        [ :set_vlan, "DEFAULT" ],
        [ :reboot, "soft" ],
        [ :wait_reboot ],
        [ :send_key_in_deploy_env, :tree ],
        [ :create_partition_table, "untrusted_env" ],
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

    def tasks()
      []
    end
  end
#end
