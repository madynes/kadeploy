require 'rights'

module Kadeploy

module Karights
  def rights_init_exec_context()
    ret = init_exec_context()
    ret.database = nil
    ret.rights = nil
    ret.nodes = nil
    ret.partitions = nil
    ret.username = nil
    ret
  end

  def rights_prepare(params,operation)
    context = rights_init_exec_context()

    context.database = database_handler()
    context.rights = rights_handler(context.database)

    # Check user/key
    parse_params_default(params,context)

    parse_params(params) do |p|
      # Check nodelist
      context.nodes = p.parse('nodes',Array,:type=>:nodeset,
        :errno=>APIError::INVALID_NODELIST)
      context.nodes = context.nodes.make_array_of_hostname if context.nodes

      # Check partition
      context.partitions = p.parse('partitions',Array)

      case operation
      when :create
        context.username = p.parse('username',String, :default => context.user)
        context.overwrite = p.parse('overwrite',nil,:toggle=>true)

      when :get
      when :delete
      else
        raise
      end
    end

    context
  end

  def rights_rights?(cexec,operation,*args)
    # check almighty
    unless config.common.almighty_env_users.include?(cexec.user)
      return [ false, 'Only administrators are allowed to manage rights' ]
    end

    return true
  end

  def rights_create(cexec)
    cexec.rights.delete(cexec.username,cexec.nodes) if cexec.overwrite
    existing = cexec.rights.get(cexec.username,cexec.nodes)
    existing = existing[cexec.username] if existing
    if existing.is_a?(Hash)
      # Some rights have to be set for every nodes but there is already some sets in the db
      if !cexec.nodes and cexec.partitions and !cexec.partitions.include?('*')
        kaerror(APIError::CONFLICTING_ELEMENTS)
      end
    elsif existing.is_a?(Array) # The user have rights on all the nodes
      if existing.include?('*') # The user have rights on all partitions
        kaerror(APIError::NOTHING_MODIFIED)
      elsif cexec.partitions and existing.sort == cexec.partitions.sort
        kaerror(APIError::NOTHING_MODIFIED)
      end
    end

    if cexec.nodes
      existing = cexec.rights.get(nil,cexec.nodes)
      # Rights already exists for another user that isnt almighty
      if existing and (existing.keys.size > 1 or existing.keys[0] != cexec.username)
        existing.keys.each do |usr|
          unless config.common.almighty_env_users.include?(usr)
            kaerror(APIError::CONFLICTING_ELEMENTS,
              "Some rights are already set for user #{usr}"\
              " on nodes #{cexec.nodes.join(',')}"
            )
          end
        end
      end
    end

    if (ret = cexec.rights.add(cexec.username,cexec.nodes,cexec.partitions))
      ret
    else
      kaerror(APIError::NOTHING_MODIFIED)
    end
  end

  def rights_get(cexec,user=nil,node=nil)
    nodes = []
    nodes << node if node
    nodes += cexec.nodes if cexec.nodes

    res = cexec.rights.get(user,nodes)
    ret = {}
    res.each do |usr,nods|
      ret[usr] = {} unless ret[usr]
      if nods.is_a?(Array)
        ret[usr]['*'] = nods
      elsif nods.is_a?(Hash)
        ret[usr] = nods
      else
        raise
      end
    end
    res = nil
    ret
  end

  def rights_modify(cexec,user,nodes=nil)
    error_invalid!
  end

  def rights_delete(cexec,user,node=nil,partition=nil)
    nodes = []
    nodes << node if node
    nodes += cexec.nodes if cexec.nodes
    nodes = nil if nodes.empty?

    existing = nil
    # nothing to delete
    kaerror(APIError::NOTHING_MODIFIED) unless existing = cexec.rights.get(user,nodes)
    existing = existing[user]

    partitions = []
    partitions << partition if partition
    partitions += cexec.partitions if cexec.partitions
    partitions = nil if partitions.empty?

    if nodes and existing.include?('*')
      kaerror(APIError::CONFLICTING_ELEMENTS,"Trying to remove rights for a specific node while rights are defined with a wildcard")
    end

    if partitions
      existing.each do |n,parts|
        if parts.include?('*')
          kaerror(APIError::CONFLICTING_ELEMENTS,"Trying to remove rights on a specific partition of node #{n} while rights are defined with a wildcard")
        end
      end
    end

    if (ret = cexec.rights.delete(user,nodes,partitions))
      ret
    else
      kaerror(APIError::NOTHING_MODIFIED)
    end
  end
end

end
