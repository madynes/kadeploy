module Kanodes
  def nodes_init_exec_context()
    ret = init_exec_context()
    ret.database = nil
    ret.nodes = nil
    ret
  end

  def nodes_prepare(params,operation=:get)
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

  def nodes_rights?(cexec,operation,*args)
    true
  end

  #def nodes_get_status(workflow_id=nil)
  #  []
  #end
  #alias_method :get_element_nodes_status, :nodes_get_status

  def nodes_get(cexec,node=nil)
    nodes = []
    nodes << node if node
    nodes += cexec.nodes if cexec.nodes
    nodes = nil if nodes.empty?

    ret = Nodes::get_states(cexec.database,nodes)

    # Check that every nodes has a state, init to nil if not
    (nodes || get_nodes()).each do |n|
      ret[n] = nil unless ret[n]
    end

    if node
      ret[node]
    else
      ret
    end
  end
end
