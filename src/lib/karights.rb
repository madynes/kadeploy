require 'rights'

module Karights
  API_DEPLOY_PATH = '/rights'

  def rights_path(path='',prefix='')
    File.join(prefix,API_DEPLOY_PATH,path)
  end

  def rights_init_exec_context()
    ret = OpenStruct.new
    ret.user = nil
    ret.database = nil
    ret
  end

  def rights_prepare(params,operation)
    context = rights_init_exec_context()

    context.database = database_handler()
    context.rights = rights_handler(context.database)

    params['user'] = params['user'][0] if params['user'].is_a?(Array)
    if !params['user'] or !params['user'].is_a?(String) or params['user'].empty?
      kaerror(APIError::NO_USER)
    end

    # Auth user
    # TODO: authentication
    context.user = params['user']


    # Check nodelist
    if params['nodes'] and !params['nodes'].empty?
      kaerror(APIError::INVALID_NODELIST) if !params['nodes'].is_a?(Array)

      context.nodes = []
      params['nodes'].each do |hostname|
        if Nodes::REGEXP_NODELIST =~ hostname
          context.nodes += Nodes::NodeSet::nodes_list_expand(hostname)
        else
          context.nodes << hostname.strip
        end
      end
    end

    # Check partition
    context.partitions = nil
    if params['partitions'] and !params['partitions'].empty?
      if params['partitions'].is_a?(Array)
        context.partitions = params['partitions']
      elsif params['partitions'].is_a?(String)
        context.partitions = [params['partitions']]
      else
        kaerror(APIError::INVALID_CONTENT,"partitions must be an Array")
      end
    end

    case operation
    when :create
      if !params['username'] or !params['username'].is_a?(String) or params['username'].empty?
        context.username = params['user']
      else
        context.username = params['username']
      end
      context.overwrite = true if params['overwrite']
    when :get
    when :delete
    else
      raise
    end

    context
  end

  def rights_rights?(cexec,operation,*args)
    # check almighty
    unless config.common.almighty_env_users.include?(cexec.user)
      [ false, 'Only administrators are allowed to set rights' ]
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
      if existing and (existing.keys.size > 1 or existing.keys[0] != cexec.username)
        kaerror(APIError::CONFLICTING_ELEMENTS,"Some rights are already set for user #{existing.keys.join(',')} on nodes #{cexec.nodes.join(',')}")
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
      existing.each do |node,parts|
        if parts.include?('*')
          kaerror(APIError::CONFLICTING_ELEMENTS,"Trying to remove rights for a node on a specific partition while rights are defined with a wildcard")
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
