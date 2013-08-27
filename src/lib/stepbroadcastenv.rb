
#Kadelpoy libs
require 'debug'
require 'macrostep'

#module MacroSteps
  class BroadcastEnv < Macrostep
    def load_config()
      super()
    end
  end

  class BroadcastEnvChain < BroadcastEnv
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

  class BroadcastEnvKastafior < BroadcastEnv
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

  class BroadcastEnvTree < BroadcastEnv
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

  class BroadcastEnvBittorrent < BroadcastEnv
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

  class BroadcastEnvCustom < BroadcastEnv
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

  class BroadcastEnvDummy < BroadcastEnv
    def steps()
      [
        [ :dummy ],
        [ :dummy ],
      ]
    end
  end
#end
