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
    def tasks()
      [
        [ :send_environment, :chain ],
        [ :manage_admin_post_install, :tree ],
        [ :manage_user_post_install, :tree ],
        [ :send_key, :tree ],
        [ :install_bootloader ],
      ]
    end
  end

  class BroadcastEnvKastafior < BroadcastEnv
    def tasks()
      [
        [ :send_environment, :kastafior ],
        [ :manage_admin_post_install, :tree ],
        [ :manage_user_post_install, :tree ],
        [ :send_key, :tree ],
        [ :install_bootloader ],
      ]
    end
  end

  class BroadcastEnvTree < BroadcastEnv
    def tasks()
      [
        [ :send_environment, :tree ],
        [ :manage_admin_post_install, :tree ],
        [ :manage_user_post_install, :tree ],
        [ :send_key, :tree ],
        [ :install_bootloader ],
      ]
    end
  end

  class BroadcastEnvBittorrent < BroadcastEnv
    def tasks()
      [
        [ :mount_tmp_part ], #we need /tmp to store the tarball
        [ :send_environment, :bittorrent ],
        [ :manage_admin_post_install, :tree ],
        [ :manage_user_post_install, :tree ],
        [ :send_key, :tree ],
        [ :install_bootloader ],
      ]
    end
  end

  class BroadcastEnvDummy < BroadcastEnv
    def start()
      true
    end

    def tasks()
      []
    end
  end
#end
