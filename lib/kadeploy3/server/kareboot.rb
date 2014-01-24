module Kadeploy

module Kareboot
  def reboot_init_exec_context(ret)
    ret = work_init_exec_context(:reboot,ret)
    ret.operation = nil
    ret.level = nil
    ret
  end

  def reboot_prepare(params,operation,context)
    context = work_prepare(:reboot,params,operation,context)
    operation ||= :create

    case operation
    when :create
      parse_params(params) do |p|
        context.operation = p.parse('kind',String,
          :values=>['set_pxe','simple','deploy_env','recorded_env']
        ).to_sym
        context.level = p.parse('level',String,
          :values=>['soft','hard','very_hard'],:default=>'soft')

        if context.operation == :recorded_env \
          and p.parse('check_destructive',nil,:toggle=>true) \
          and context.nodes.check_demolishing_env(context.database)
        then
          kaerror(APIError::DESTRUCTIVE_ENVIRONMENT)
        end
      end

      case context.operation
      when :set_pxe
        if !context.pxe or !context.pxe[:profile] or context.pxe[:profile].empty?
          kaerror(APIError::MISSING_OPTION,"You must specify a PXE boot profile when rebooting using set_pxe")
        end
      when :recorded_env
        if !context.environment or context.environment.id < 0
          kaerror(APIError::MISSING_OPTION,"You must specify an environment when rebooting using recorded_env")
        end
        if !context.deploy_part or context.deploy_part.empty?
          kaerror(APIError::MISSING_OPTION,"You must specify a partition when rebooting using recorded_env")
        end
      end
    when :get
    end

    context
  end
end

end
