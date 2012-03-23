# Kadeploy 3.1
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2011
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

#Kadelpoy libs
require 'debug'
require 'macrostep'

module MacroSteps
  class SetDeploymentEnv < MacroStep
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
        1
      )

    end
  end

  class SetDeploymentEnvUntrusted < SetDeploymentEnv
    def microsteps()
      ret = true
      ret = ret && @step.switch_pxe("prod_to_deploy_env", "")
      ret = ret && @step.set_vlan("DEFAULT")
      ret = ret && @step.reboot("soft", (@currentretry == 0))
      ret = ret && @step.wait_reboot
      ret = ret && @step.send_key_in_deploy_env("tree")
      ret = ret && @step.create_partition_table("untrusted_env")
      ret = ret && @step.format_deploy_part
      ret = ret && @step.mount_deploy_part
      ret = ret && @step.format_tmp_part
      ret = ret && @step.format_swap_part
      return ret
    end
  end

  class SetDeploymentEnvKexec < SetDeploymentEnv
    def microsteps()
      ret = true
      ret = ret && @step.switch_pxe("prod_to_deploy_env", "")
      ret = ret && @step.set_vlan("DEFAULT")
      ret = ret && @step.create_kexec_repository
      ret = ret && @step.send_deployment_kernel("tree")
      ret = ret && @step.kexec(
        'linux',
        @config.cluster_specific[@cluster].kexec_repository,
        @config.cluster_specific[@cluster].deploy_kernel,
        @config.cluster_specific[@cluster].deploy_initrd,
        @config.cluster_specific[@cluster].deploy_kernel_args
      )
      ret = ret && @step.wait_reboot("kexec")
      ret = ret && @step.send_key_in_deploy_env("tree")
      ret = ret && @step.create_partition_table("untrusted_env")
      ret = ret && @step.format_deploy_part
      ret = ret && @step.mount_deploy_part
      ret = ret && @step.format_tmp_part
      ret = ret && @step.format_swap_part
      return ret
    end
  end

  class SetDeploymentEnvUntrustedCustomPreInstall < SetDeploymentEnv
    def microsteps()
      ret = true
      ret = ret && @step.switch_pxe("prod_to_deploy_env")
      ret = ret && @step.set_vlan("DEFAULT")
      ret = ret && @step.reboot("soft", (@currentretry == 0))
      ret = ret && @step.wait_reboot
      ret = ret && @step.send_key_in_deploy_env("tree")
      ret = ret && @step.manage_admin_pre_install("tree")
      return ret
    end
  end

  class SetDeploymentEnvProd < SetDeploymentEnv
    def microsteps()
      ret = true
      ret = ret && @step.check_nodes("prod_env_booted")
      ret = ret && @step.create_partition_table("prod_env")
      ret = ret && @step.format_deploy_part
      ret = ret && @step.mount_deploy_part
      ret = ret && @step.format_tmp_part
      return ret
    end
  end

  class SetDeploymentEnvNfsroot < SetDeploymentEnv
    def microsteps()
      ret = true
      ret = ret && @step.switch_pxe("prod_to_nfsroot_env")
      ret = ret && @step.set_vlan("DEFAULT")
      ret = ret && @step.reboot("soft", (@currentretry == 0))
      ret = ret && @step.wait_reboot
      ret = ret && @step.send_key_in_deploy_env("tree")
      ret = ret && @step.create_partition_table("untrusted_env")
      ret = ret && @step.format_deploy_part
      ret = ret && @step.mount_deploy_part
      ret = ret && @step.format_tmp_part
      ret = ret && @step.format_swap_part
      return ret
    end
  end

  class SetDeploymentEnvDummy < SetDeploymentEnv
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
