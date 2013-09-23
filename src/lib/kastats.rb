module Kadeploy

module Kastats
  def stats_init_exec_context()
    ret = init_exec_context()
    ret.database = nil
    ret.nodes = nil
    ret
  end

  def stats_prepare(params,operation=:get)
    context = nodes_init_exec_context()
    parse_params_default(params,context)

    context.database = database_handler()

    # Check user/key
    parse_params_default(params,context)

    parse_params(params) do |p|
      # Check nodelist
      context.nodes = p.parse('nodes',Array,:type=>:nodeset,
        :errno=>APIError::INVALID_NODELIST)
      context.nodes = context.nodes.make_array_of_hostname if context.nodes
    end

    context
  end

  def stats_rights?(cexec,operation,names,*args)
    true
  end

  def stats_get(cexec)
  end
end

end
