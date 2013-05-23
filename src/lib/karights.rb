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
    context.database = database_handler()

    if !params['user'] or !params['user'].is_a?(String) or params['user'].empty?
      kaerror(APIError::NO_USER)
    end

    # Auth user
    # TODO: authentication


    # Check nodelist
    if !params['nodes'] or !params['nodes'].is_a?(Array) or params['nodes'].empty?
      kaerror(APIError::INVALID_NODELIST)
    end

    context.nodes = []
    params['nodes'].each do |hostname|
      if Nodes::REGEXP_NODELIST =~ hostname
        context.nodes += Nodes::NodeSet::nodes_list_expand(hostname)
      else
        context.nodes << hostname.strip
      end
    end

    # Check partitions
    context.partitions = nil
    if params['partitions']
      if params['partitions'].is_a?(Array)
        context.partitions = params['partitions'] unless params['partitions'].empty?
      else
        kaerror(APIError::INVALID_CONTENT,"partitions must be an array")
      end
    end

    case operation
    when :create
      if !params['username'] or !params['username'].is_a?(String) or params['username'].empty?
        context.user = params['user']
      else
        context.user = params['username']
      end
      context.overwrite = params['overwrite']
    when :get
    when :delete
    else
      raise
    end
  end

  def rights_rights?(cexec,operation,*args)
    # check almighty
    unless config.common.almighty_env_users.include?(cexec.user)
      [ false, 'Only administrators are allowed to set rights' ]
    end
  end

  def rights_create(cexec)
    # Make a .uniq! on node and partition set
    existing = Rights.get(cexec.user,cexec.nodes)
    if !existing.empty?
      if cexec.overwrite
        kaerror(APIError::EXISTING_ELEMENT,"Some rights are already set on nodes #{existing.keys.join(',')}")
      else
        #nodelist = ("(node = ? )" * existing.size).join(' OR ')
        #query = "DELETE FROM rights WHERE part<>\"*\" AND (#{nodelist})"
        #cexec.database.run_query(query,*existing.keys.dup)
        Rights.delete(cexec.user,existing.keys.dup)
      end
    end
    # add on every nodes if nodes.empty?
    # do not forget to exclude nodes where rights are set on *
    Rights.add(cexec.user,cexec.nodes)
  end

  def rights_get(cexec,user,node=nil)
    nodes = []
    nodes << node if node
    nodes += cexec.nodes if cexec.nodes

    Rights.get(user,nodes)
  end

  def rights_modify(cexec,user,nodes=nil)
    error_invalid!
  end

  def rights_delete(cexec,user,node=nil,partition=nil)
    nodes = []
    nodes << node if node
    nodes += cexec.nodes if cexec.nodes

    partitions = []
    partitions << partition if partition
    partitions += cexec.partitions if cexec.partitions

    Rights.delete(user,nodes,partitions)
  end
end
