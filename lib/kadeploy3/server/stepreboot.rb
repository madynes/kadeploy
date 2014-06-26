module Kadeploy

module Macrostep
  class RebootSimple < Reboot
    def steps()
      [
        [ :reboot, context[:execution].level ],
        [ :set_vlan ],
        [ :wait_reboot, 'classical', 'user', true ],
      ]
    end
  end

  class RebootSetPXE < Reboot
    def steps()
      [
        [ :switch_pxe, 'set_pxe', context[:execution].pxe[:profile] ],
        [ :reboot, context[:execution].level ],
        [ :set_vlan ],
        [ :wait_reboot, 'classical', 'user', true ],
      ]
    end
  end

  class RebootDeployEnv < Reboot
    def steps()
      [
        [ :switch_pxe, 'prod_to_deploy_env' ],
        [ :reboot, context[:execution].level ],
        [ :set_vlan ],
        [ :wait_reboot, 'classical', 'deploy', true ],
        [ :send_key_in_deploy_env, :tree ],
        #[ :check_nodes, 'deployed_env_booted' ],
      ]
    end
  end

  class RebootRecordedEnv < Reboot
    def steps()
      [
        [ :switch_pxe, 'deploy_to_deployed_env' ],
        [ :reboot, context[:execution].level ],
        [ :set_vlan ],
        [ :wait_reboot, 'classical', 'user', true ],
        #[ :check_nodes, 'prod_env_booted' ],
      ]
    end
  end
end

end

