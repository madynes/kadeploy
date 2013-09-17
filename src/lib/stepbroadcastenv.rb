require 'debug'
require 'macrostep'

module Kadeploy

module Macrostep
  class DeployBroadcastEnv < Deploy
    def load_config()
      super()
    end
  end

  class DeployBroadcastEnvChain < DeployBroadcastEnv
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

  class DeployBroadcastEnvKastafior < DeployBroadcastEnv
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

  class DeployBroadcastEnvTree < DeployBroadcastEnv
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

  class DeployBroadcastEnvBittorrent < DeployBroadcastEnv
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

  class DeployBroadcastEnvCustom < DeployBroadcastEnv
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

  class DeployBroadcastEnvDummy < DeployBroadcastEnv
    def steps()
      [
        [ :dummy ],
        [ :dummy ],
      ]
    end
  end
end

end
