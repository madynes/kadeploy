module Kadeploy
  API_DEPLOY_PATH = '/deploy'

  def deploy_path(path='',prefix='')
    File.join(prefix,API_DEPLOY_PATH,path)
  end

  def deploy_check_params(params)
    context = {}

    # Check user
    if !params['user'] or !params['user'].is_a?(String) or params['user'].empty?
      kaerror(APIError::NO_USER)
    end
    context[:user] = params['user']
    # TODO: authentication

    # Check nodelist
    if !params['nodes'] or !params['nodes'].is_a?(Array) or params['nodes'].empty?
      kaerror(APIError::INVALID_NODELIST)
    end

    # Check that nodes exists
    hosts = []
    params['nodes'].each do |hostname|
      if Nodes::REGEXP_NODELIST =~ hostname
        hosts += Nodes::NodeSet::nodes_list_expand(hostname)
      else
        hosts << hostname.strip
      end
    end

    # Create a nodeset
    context[:nodes] = Nodes::NodeSet.new(0)
    context[:nodelist] = []
    hosts.each do |hostname|
      if node = config.common.nodes_desc.get_node_by_host(hostname)
        context[:nodes].push(node)
        context[:nodelist] << hostname
      else
        kaerror(KadeployAsyncError::NODE_NOT_EXIST,hostname)
      end
    end

    # Check VLAN
    if params['vlan']
      if config.common.vlan_hostname_suffix.empty? or config.common.set_vlan_cmd.empty?
        kaerror(KadeployAsyncError::VLAN_MGMT_DISABLED)
      else
        context[:vlan_id] = params['vlan']
        dns = Resolv::DNS.new
        context[:vlan_addr] = {}
        context[:nodelist].each do |hostname|
          host,domain = hostname.split('.',2)
          vlan_hostname = "#{host}#{config.common.vlan_hostname_suffix}"\
            ".#{domain}".gsub!('VLAN_ID', context[:vlan_id])
          begin
            context[:vlan_addr] = dns.getaddress(vlan_hostname).to_s
          rescue Resolv::ResolvError
            kaerror(KadeployAsyncError::NODE_NOT_EXIST,"DNS:#{vlan_hostname}")
          end
        }
        dns.close
        dns = nil
      end
    end

    # Check Environment
    env = params['environment']
    if !env or !env.is_a?(Hash) or env.empty?
      kaerror(KadeployAsyncError::NO_ENV_CHOSEN)
    end

    if !env['kind'] or env['kind'].empty?
      kaerror(APIError::INVALID_ENVIRONMENT,'\'kind\' field missing')
    end

    context[:environment] = Environment.new

    case env['kind']
    when 'anonymous'
      unless context[:environment].load_from_file(
        env['name'],
        config.common.almighty_env_users,
        context[:user],
        client, ###
        false,
        exec_specific_config.load_env_file ###
      ) then
        kaerror(KadeployAsyncError::LOAD_ENV_FROM_FILE_ERROR)
      end
    when 'database'
      if !env['user'] or env['user'].empty?
        kaerror(APIError::INVALID_ENVIRONMENT,'\'user\' field missing')
      end

      unless context[:environment].load_from_db(
        db, ###
        env['name'],
        env['version'],
        env['user'],
        env['user'] == context[:user],
        env['user'].nil?
      ) then
        kaerror(KadeployAsyncError::LOAD_ENV_FROM_DB_ERROR,"#{env['name']},#{env['version']}/#{env['user']}")
      end
    else
      kaerror(APIError::INVALID_ENVIRONMENT,'invalid \'kind\' field')
    end
    env = nil

    # Multi-partitioned archives hack
    if context[:environment].multipart
      params['block_device'] = context[:environment].options['block_device']
      params['deploy_part'] = context[:environment].options['deploy_part']
    end

    #Rights check
    #The rights must be checked for each cluster if the node_list contains nodes from several clusters
    context[:nodes].group_by_cluster.each_pair do |cluster, nodes|
      b = params['block_device'] || config.cluster_specific[cluster].block_device
      p=nil
      if params['deploy_part'].nil?
        p = ''
      elsif params['deploy_part'].empty?
        p = config.cluster_specific[cluster].deploy_part
      else
        p = params['deploy_part']
      end

      part = b + p
      unless CheckRights::CheckRightsFactory.create(
        config.common.rights_kind, context[:user],
        client, set, db, part ###
      ).granted?
        kaerror(KadeployAsyncError::NO_RIGHT_TO_DEPLOY)
      end
    end

    # Check rights on multipart environement
    if context[:environment].multipart
      context[:environment].options['partitions'].each do |part|
        unless CheckRights::CheckRightsFactory.create(
          config.common.rights_kind, context[:user], client,
          exec_specific_config.node_set, db, part['device'] ###
        ).granted?
          kaerror(KadeployAsyncError::NO_RIGHT_TO_DEPLOY)
        end
      end
    end

    context
  end

  def deploy_run(context)
    info = {
      :wid => uuid('D-'),
      :start_time => Time.now,
      :done => false,
      :nodelist => context[:nodelist],
      :nodes => {}, # Hash, one key per node + current status
      :workflows => [],
    }

    info[:thread] = Thread.new do
      wid = info[:wid].dup
      sleep 3
    end

    create_workflow(:deploy,info[:wid],info)

    info[:wid]
  end

  def deploy_get(wid)
    get_workflow(:deploy,wid) do |info|
      done = nil
      if info[:thread].alive?
        done = false
      else
        info[:thread].join
        done = true
        info[:done] = true
      end
      {
        :nodelist => info[:nodelist],
        :time => (Time.now - info[:start_time]).round(2),
        :done => done,
      }
    end
  end

  def deploy_delete(wid)
    delete_workflow(:deploy,wid) do |info|
      info[:thread].kill if info[:thread].alive?
      info[:workflows].each do |workflow|
        workflow.kill
        workflow.free
      end
      GC.start
      { :wid => wid }
    end
  end
end
