require 'debug'
require 'macrostep'

module Kadeploy

module Macrostep
  class KadeployBroadcastEnv < Kadeploy
    def load_config()
      super()
    end
  end

  class KadeployBroadcastEnvChain < KadeployBroadcastEnv
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

  class KadeployBroadcastEnvKastafior < KadeployBroadcastEnv
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

  class KadeployBroadcastEnvTree < KadeployBroadcastEnv
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

  class KadeployBroadcastEnvBittorrent < KadeployBroadcastEnv
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

  class KadeployBroadcastEnvCustom < KadeployBroadcastEnv
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

  class KadeployBroadcastEnvDummy < KadeployBroadcastEnv
    def steps()
      [
        [ :dummy ],
        [ :dummy ],
      ]
    end
  end
end

end
