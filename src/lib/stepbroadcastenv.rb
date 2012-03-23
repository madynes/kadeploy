# Kadeploy 3.1
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2011
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

#Kadelpoy libs
require 'debug'
require 'macrostep'

module MacroSteps
  class BroadcastEnv < MacroStep
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
        2
      )

    end
  end

  class BroadcastEnvChain < BroadcastEnv
    def microsteps()
      ret = true
      ret = ret && @step.send_environment("chain")
      ret = ret && @step.manage_admin_post_install("tree")
      ret = ret && @step.manage_user_post_install("tree")
      ret = ret && @step.send_key("tree")
      ret = ret && @step.install_bootloader
      return ret
    end
  end

  class BroadcastEnvKastafior < BroadcastEnv
    def microsteps()
      ret = true
      ret = ret && @step.send_environment("kastafior")
      ret = ret && @step.manage_admin_post_install("tree")
      ret = ret && @step.manage_user_post_install("tree")
      ret = ret && @step.send_key("tree")
      ret = ret && @step.install_bootloader
      return ret
    end
  end

  class BroadcastEnvTree < BroadcastEnv
    def microsteps()
      ret = true
      ret = ret && @step.send_environment("tree")
      ret = ret && @step.manage_admin_post_install("tree")
      ret = ret && @step.manage_user_post_install("tree")
      ret = ret && @step.send_key("tree")
      ret = ret && @step.install_bootloader
      return ret
    end
  end

  class BroadcastEnvBittorrent < BroadcastEnv
    def microsteps()
      ret = true
      ret = ret && @step.mount_tmp_part #we need /tmp to store the tarball
      ret = ret && @step.send_environment("bittorrent")
      ret = ret && @step.manage_admin_post_install("tree")
      ret = ret && @step.manage_user_post_install("tree")
      ret = ret && @step.send_key("tree")
      ret = ret && @step.install_bootloader
      return ret
    end
  end

  class BroadcastEnvDummy < BroadcastEnv
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
