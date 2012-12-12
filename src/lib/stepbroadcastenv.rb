# Kadeploy 3.1
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2011
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

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
        [ :manage_admin_post_install, :tree ],
        [ :manage_user_post_install, :tree ],
        [ :check_kernel_files ],
        [ :send_key, :tree ],
        [ :install_bootloader ],
      ]
    end
  end

  class BroadcastEnvKastafior < BroadcastEnv
    def steps()
      [
        [ :send_environment, :kastafior ],
        [ :manage_admin_post_install, :tree ],
        [ :manage_user_post_install, :tree ],
        [ :check_kernel_files ],
        [ :send_key, :tree ],
        [ :install_bootloader ],
      ]
    end
  end

  class BroadcastEnvTree < BroadcastEnv
    def steps()
      [
        [ :send_environment, :tree ],
        [ :manage_admin_post_install, :tree ],
        [ :manage_user_post_install, :tree ],
        [ :check_kernel_files ],
        [ :send_key, :tree ],
        [ :install_bootloader ],
      ]
    end
  end

  class BroadcastEnvBittorrent < BroadcastEnv
    def steps()
      [
        [ :mount_tmp_part ], #we need /tmp to store the tarball
        [ :send_environment, :bittorrent ],
        [ :manage_admin_post_install, :tree ],
        [ :manage_user_post_install, :tree ],
        [ :check_kernel_files ],
        [ :send_key, :tree ],
        [ :install_bootloader ],
      ]
    end
  end

  class BroadcastEnvDummy < BroadcastEnv
    def start()
      true
    end

    def steps()
      []
    end
  end
#end
