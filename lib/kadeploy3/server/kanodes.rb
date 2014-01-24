module Kadeploy

module Kanodes
  def nodes_init_exec_context(ret)
    ret.nodes = nil
    ret.list = nil
    ret
  end

  def nodes_prepare(params,operation,context)
    context = nodes_init_exec_context(context)
    operation ||= :get

    parse_params(params) do |p|
      # Check nodelist
      context.nodes = p.parse('nodes',Array,:type=>:nodeset,
        :errno=>APIError::INVALID_NODELIST)
      if context.nodes
        tmp = context.nodes.make_array_of_hostname
        context.nodes.free
        context.nodes = tmp
      end
      context.list = p.parse('list',nil,:toggle=>true)
    end

    context
  end

  def nodes_get(cexec,node=nil)
    nodes = []
    nodes << node if node
    nodes += cexec.nodes if cexec.nodes
    nodes = nil if nodes.empty?

    server_nodes = get_nodes()

    if cexec.list
      nodes.each{|n| error_not_found!(n) unless server_nodes.include?(n)} if nodes
      nodes || server_nodes
    else
      ret = Nodes::get_states(cexec.database,nodes)
      error_not_found!(node) if nodes and (!ret or ret.empty?)

      # Check that every nodes has a state, init to nil if not
      (nodes || server_nodes).each do |n|
        ret[n] = nil unless ret[n]
      end

      if node
        ret[node]
      else
        ret
      end
    end
  end
end

end
