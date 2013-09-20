require 'uri'

require 'grabfile'
require 'workflow'
require 'kaworkflow'

module Kadeploy

module Kadeploy
  def deploy_init_exec_context()
    ret = work_init_exec_context(:deploy)
    ret.reformat_tmp = nil
    ret.disable_bootloader_install = false
    ret.disable_disk_partitioning = false
    ret.timeout_reboot_kexec = nil
    ret
  end

  def deploy_prepare(params,operation=:create)
    context = work_prepare(:deploy,params,operation)

    # Check user
    parse_params_default(params,context)

    case operation
    when :create
      parse_params(params) do |p|
        # Check Anonymous Environment
        if context.environment and !context.environment.id
          env = p.parse('environment',Hash,:mandatory=>true)
          env.delete('kind')

          unless context.environment.load_from_desc(
            env,
            config.common.almighty_env_users,
            context.user,
            context.client
          ) then
            kaerror(APIError::INVALID_ENVIRONMENT,'the environment cannot be loaded from the description you specified')
          end
        end

        # Multi-partitioned archives hack
        if context.environment.multipart
          part = context.environment.options['block_device'] + \
            context.environment.options['deploy_part']
          kaerror(APIError::INVALID_RIGHTS,"deployment on partition #{part}") \
            unless context.rights.granted?(context.user,nodes,part)
        end

        # Check rights on the deploy partition on nodes by cluster
        # TODO: use context.block_device and context.deploy_part
        context.nodes.group_by_cluster.each_pair do |cluster, nodes|
          part = (
            p.parse('block_device',String,
              :default=>config.cluster_specific[cluster].block_device) \
            + p.parse('deploy_partition',String,:emptiable=>true,
              :default=>config.cluster_specific[cluster].deploy_part)
          )
          kaerror(APIError::INVALID_RIGHTS,"deployment on partition #{part}") \
            unless context.rights.granted?(context.user,nodes,part)
        end

        # Check the boot partition
        context.boot_part = p.parse('boot_partition',Fixnum)

        # Check disable options
        context.disable_bootloader_install = p.parse('disable_bootloader_install',nil,:toggle=>true)
        context.disable_disk_partitioning = p.parse('disable_disk_partitioning',nil,:toggle=>true)

        # Check rights on multipart environement
        if context.environment.multipart
          context.environment.options['partitions'].each do |par|
            unless context.rights.granted?(context.user,context.nodes,par['device'])
              kaerror(APIError::INVALID_RIGHTS,"deployment on partition #{par['device']}")
            end
          end
        end

        # Check reformat tmp partition
        context.reformat_tmp = p.parse('reformat_tmp_partition',String)

        # Check custom automata
        context.steps = p.parse('automata',Hash,:type=>:custom_automata)

        # Check kexec timeout
        p.parse('timeout_reboot_kexec',String) do |timeout|
          begin
            eval("n=1; #{timeout}")
          rescue
            kaerror(APIError::INVALID_OPTION,
              "the timeout is not a valid expression (#{e.message})")
          end
          context.timeout_reboot_kexec = timeout
        end
      end
    when :get
    when :delete
    else
      raise
    end

    context
  end
end

end
