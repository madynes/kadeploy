module Kadeploy

module Kapower
  def power_init_exec_context()
    ret = work_init_exec_context(:power)
    ret.operation = nil
    ret.level = nil
    ret
  end

  def power_init_info(cexec)
    work_init_info(:power,cexec,'P-')
  end

  def power_prepare(params,operation=:create)
    context = work_prepare(:power,params,operation)

    # Check user
    parse_params_default(params,context)

    case operation
    when :modify
      parse_params(params) do |p|
        context.operation = p.parse('status',String,:values=>['on','off']).to_sym
        context.level = p.parse('level',String,
          :values=>['soft','hard','very_hard'],:default=>'soft')
      end
      context.info = run_wmethod(:power,:init_info,context)
    when :get
      parse_params(params) do |p|
        # Check nodelist
        context.nodes = p.parse('nodes',Array,:type=>:nodeset,
          :errno=>APIError::INVALID_NODELIST)
        context.nodelist = context.nodes.make_array_of_hostname if context.nodes
      end
      context.operation = :status
    end

    context
  end

  def power_get(cexec,wid=nil)
    if !wid and cexec.nodes
      # TODO: do it a better way
      #->power_prepare(cexec,:modify)
      cexec.database = database_handler()
      cexec.rights = rights_handler(cexec.database)
      cexec.info = run_wmethod(:power,:init_info,cexec)
      kaerror(APIError::INVALID_RIGHTS) \
        unless cexec.rights.granted?(cexec.user,cexec.nodes,'')

      work_create(:power,cexec) do |info|
        info[:output].push(0,'---')
        #info[:nodes].set.each do |node|
        #  info[:output].push(0,"  #{node.hostname}: #{node.last_cmd_stdout}")
        #end
        info[:output].push(0,info[:nodes].to_s(true,false,"\n"))
        info[:output].push(0,'---')
      end
    else
      work_get(:power,cexec,wid)
    end
  end

  def power_modify(*args)
    work_create(:power,*args)
  end
end

end
