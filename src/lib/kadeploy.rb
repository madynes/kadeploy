require 'uri'
require 'ostruct'

require 'grabfile'
require 'workflow'

DEPLOY_STATUS_CHECK_PITCH=1

module Kadeploy
  API_DEPLOY_PATH = '/deploy'

  def deploy_path(path='',prefix='')
    File.join(prefix,API_DEPLOY_PATH,path)
  end

  def deploy_init_exec_context()
    ret = OpenStruct.new
    ret.nodes = nil
    ret.nodelist = nil
    ret.environment = nil
    ret.env_kind = nil
    ret.user = nil
    ret.block_device = String.new
    ret.deploy_part = String.new
    ret.boot_part = nil
    ret.verbose_level = nil
    ret.debug = false
    ret.key = String.new
    ret.reformat_tmp = false
    ret.pxe_profile_msg = String.new
    ret.pxe_profile_singularities = nil
    ret.pxe_upload_files = Array.new
    ret.steps = Array.new
    ret.ignore_nodes_deploying = false
    ret.breakpoint = nil
    ret.breakpointed = false
    ret.custom_operations = nil
    ret.disable_bootloader_install = false
    ret.disable_disk_partitioning = false
    ret.timeout_reboot_classical = nil
    ret.timeout_reboot_kexec = nil
    ret.vlan_id = nil
    ret.vlan_addr = nil
    ret.client = nil
    ret.output = nil
    ret.outputfile = nil
    ret.logger = nil
    ret.loggerfile = nil
    ret
  end

  def deploy_prepare(params)
    context = deploy_init_exec_context()

    # Check user
    if !params['user'] or !params['user'].is_a?(String) or params['user'].empty?
      kaerror(APIError::NO_USER)
    end
    context.user = params['user']
    # TODO: authentication


    # Check client
    if params['client']
      begin
        context.client = URI.parse(params['client'])
        kaerror(
          APIError::INVALID_CLIENT,'Invalid client protocol'
        ) unless ['http','https'].include?(context.client.scheme.downcase)

        kaerror(
          APIError::INVALID_CLIENT,'Secure connection is mandatory for the client fileserver'
        ) if config.common.secure_client and context.client.scheme.downcase == 'http'
      rescue
        kaerror(APIError::INVALID_CLIENT,'Invalid client URI')
      end
    end

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
    context.nodes = Nodes::NodeSet.new(0)
    context.nodelist = []
    hosts.each do |hostname|
      if node = config.common.nodes_desc.get_node_by_host(hostname)
        context.nodes.push(node)
        context.nodelist << hostname
      else
        kaerror(KadeployError::NODE_NOT_EXIST,hostname)
      end
    end

    # Check database
    context.database = database_handler()

    # Check VLAN
    if params['vlan']
      if config.common.vlan_hostname_suffix.empty? or config.common.set_vlan_cmd.empty?
        kaerror(KadeployError::VLAN_MGMT_DISABLED)
      else
        context.vlan = params['vlan']
        dns = Resolv::DNS.new
        context.vlan_addr = {}
        context.nodelist.each do |hostname|
          host,domain = hostname.split('.',2)
          vlan_hostname = "#{host}#{config.common.vlan_hostname_suffix}"\
            ".#{domain}".gsub!('VLAN_ID', context.vlan_id)
          begin
            context.vlan_addr = dns.getaddress(vlan_hostname).to_s
          rescue Resolv::ResolvError
            kaerror(KadeployError::NODE_NOT_EXIST,"DNS:#{vlan_hostname}")
          end
        end
        dns.close
        dns = nil
      end
    end

    # Check PXE
    if params['pxe']
      if params['pxe'].is_a?(Hash) and !params['pxe'].empty?
        context.pxe_profile_msg = params['pxe']['profile'] if params['pxe']['profile'] and !params['pxe']['profile'].empty?

        # TODO: check singularities
        context.pxe_profile_singularities = params['pxe']['singularities'] if params['pxe']['sintularities'] and !params['pxe']['singularities'].empty?

        if params['pxe']['files']
          if params['pxe']['files'].is_a?(Array) and !params['pxe']['files'].empty?
            context.pxe_upload_files = params['pxe']['files']
          else
            kaerror(FetchFileError::INVALID_PXE_FILE,'field \'pxe/files\' must be a non-empty array')
          end
        end
      else
        kaerror(FetchFileError::INVALID_PXE_FILE,'field \'pxe\' must be a non-empty object')
      end
    end

    # TODO: check custom operations

    # Check Environment
    env = params['environment']
    if !env or !env.is_a?(Hash) or env.empty?
      kaerror(KadeployError::NO_ENV_CHOSEN)
    end

    if !env['kind'] or env['kind'].empty?
      kaerror(APIError::INVALID_ENVIRONMENT,'\'kind\' field missing')
    end

    context.environment = EnvironmentManagement::Environment.new

    case env['kind']
    when 'anonymous'
      env.delete('kind')
      unless context.environment.load_from_desc(
        env,
        config.common.almighty_env_users,
        context.user,
        context.client
      ) then
        kaerror(KadeployError::LOAD_ENV_FROM_DESC_ERROR)
      end
      context.env_kind = :anon
    when 'database'
      if !env['user'] or env['user'].empty?
        kaerror(APIError::INVALID_ENVIRONMENT,'\'user\' field missing')
      end

      unless context.environment.load_from_db(
        context.database,
        env['name'],
        env['version'],
        env['user'],
        env['user'] == context.user,
        env['user'].nil?
      ) then
        kaerror(KadeployError::LOAD_ENV_FROM_DB_ERROR,"#{env['name']},#{env['version']}/#{env['user']}")
      end
      context.env_kind = :db
    else
      kaerror(APIError::INVALID_ENVIRONMENT,'invalid \'kind\' field')
    end
    env = nil

    # Multi-partitioned archives hack
    if context.environment.multipart
      params['block_device'] = context.environment.options['block_device']
      params['deploy_part'] = context.environment.options['deploy_part']
    end

    #Rights check
    #The rights must be checked for each cluster if the node_list contains nodes from several clusters
    context.nodes.group_by_cluster.each_pair do |cluster, nodes|
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
        config.common.rights_kind, context.user,
        context.client, nodes, context.database, part
      ).granted?
        kaerror(KadeployError::NO_RIGHT_TO_DEPLOY,part)
      end
    end

    # Check rights on multipart environement
    if context.environment.multipart
      context.environment.options['partitions'].each do |part|
        unless CheckRights::CheckRightsFactory.create(
          config.common.rights_kind, context.user, context.client,
          context.nodes, context.database, part['device']
        ).granted?
          kaerror(KadeployError::NO_RIGHT_TO_DEPLOY)
        end
      end
    end

    # Check force
    if params['force']
      if [TrueClass,FalseClass].include?(params['force'].class)
        context.ignore_nodes_deploying = params['force']
      else
        kaerror(APIError::INVALID_OPTION,'field \'force\' must be boolean')
      end
    end

    # Check debug
    if params['debug']
      if [TrueClass,FalseClass].include?(params['debug'].class)
        context.debug = params['debug']
      else
        kaerror(APIError::INVALID_OPTION,'field \'debug\' must be boolean')
      end
    end

    # Loading OutputControl
    if config.common.dbg_to_file and !config.common.dbg_to_file.empty?
      context.outputfile = Debug::FileOutput.new(config.common.dbg_to_file,
        config.common.dbg_to_file_level)
    end

    if config.common.log_to_file and !config.common.log_to_file.empty?
      context.loggerfile = Debug::FileOutput.new(config.common.log_to_file)
    end

    context
  end

  def deploy_run(cexec)
    info = {
      :wid => uuid('D-'),
      :start_time => Time.now,
      :done => false,
      :nodelist => cexec.nodelist,
      :clusterlist => cexec.nodes.group_by_cluster.keys,
      :nodes => cexec.nodes,
      :state => Nodes::NodeState.new(),
      :database => cexec.database,
      :environment => cexec.environment,
      :workflows => {},
      :threads => {},
      :cached_files => nil,
      :output => Debug::OutputControl.new(
        cexec.verbose_level || config.common.verbose_level,
        cexec.outputfile,
        ''
      ),
      :debugger => (cexec.debug ? Debug::DebugControl.new() : nil),
      :resources => {},
      :bindings => [],
    }

    workflows = info[:workflows]
    create_workflow(:deploy,info[:wid],info) do
      info[:thread] = Thread.new do
        #sleep 3

        context = {
          :wid => info[:wid].dup,
          :user => cexec.user,
          #:nodelist => cexec.nodelist,
          #:nodes => cexec.nodes,
          :states => info[:state],
          :nodesets_id => 0,

          :execution => cexec,
          :config => config,
          :common => config.common,
          :cluster => nil,

          :database => cexec.database,

          :windows => @window_managers,
          :debugger => info[:debugger],
        }


        # Cache the deployment files
        begin
          info[:cached_files] = GrabFile.grab_user_files(context)
        rescue KadeployError => ke
          info[:nodes].set_deployment_state('aborted',nil,cexec.database,cexec.user)
          raise ke
        end


        # Set clusters IDs
        clusters = info[:nodes].group_by_cluster
        if clusters.size > 1
          clid = 1
        else
          clid = 0
        end

        # Run a Workflow by cluster
        clusters.each_pair do |cluster,nodeset|
          context[:cluster] = config.cluster_specific[cluster]
          if clusters.size > 1
            if context[:cluster].prefix.empty?
              context[:cluster].prefix = "c#{clid}"
              clid += 1
            end
          else
            context[:cluster].prefix = ''
          end

          cexec.outputfile.prefix = "#{context[:wid]}|#{cexec.user} -> " if cexec.outputfile
          context[:output] = Debug::OutputControl.new(
            cexec.verbose_level || config.common.verbose_level,
            cexec.outputfile,
            context[:cluster].prefix
          )
          context[:logger] = Debug::Logger.new(
            cexec.nodelist,
            cexec.user,
            context[:wid],
            Time.now,
            "#{context[:execution].environment.name}:#{context[:execution].environment.version.to_s}",
            context[:execution].env_kind == :anon,
            cexec.loggerfile,
            (config.common.log_to_db ? context[:database] : nil)
          )

          workflow = Workflow.new(nodeset,context.dup)

          workflows[cluster] = workflow
        end

        output = info[:output]

        # Print debug
        if clusters.size > 1
          tmp = ''
          workflows.each do |workflow|
            tmp += "  #{Debug.prefix(workflow.context[:cluster].prefix)}: #{workflow.context[:cluster].name}\n"
          end
          output.push(0,"\nClusters involved in the deployment:\n#{tmp}\n") if output
        end

        # Run every workflows
        workflows.each_value{ |wf| info[:threads][wf] = wf.run! }
        # Wait for cleaners to be started
        workflows.each_value{ |wf| sleep(0.2) until (wf.cleaner) }
        # Wait for deployments to end
        dones = []
        until (dones.size >= workflows.size)
          workflows.each_value do |workflow|
            if !dones.include?(workflow) and workflow.done?
              info[:threads][workflow].join
              dones << workflow
            else
              workflow.cleaner.join if workflow.cleaner and !workflow.cleaner.alive?
            end
          end
          sleep(DEPLOY_STATUS_CHECK_PITCH)
        end

        # Print debug
        workflows.each_value do |workflow|
          clname = workflow.context[:cluster].name
          output.push(0,"")
          unless workflow.nodes_brk.empty?
            output.push(0,"Nodes breakpointed on cluster #{clname}")
            output.push(0,workflow.nodes_brk.to_s(false,false,"\n"))
          end
          unless workflow.nodes_ok.empty?
            output.push(0,"Nodes correctly deployed on cluster #{clname}")
            output.push(0,workflow.nodes_ok.to_s(false,false,"\n"))
          end
          unless workflow.nodes_ko.empty?
            output.push(0,"Nodes not correctly deployed on cluster #{clname}")
            output.push(0,workflow.nodes_ko.to_s(false,true,"\n"))
          end
        end

        # Clean everything
        info[:cached_files].each{|file| file.release } if info[:cached_files]
        config.common.cache[:global].clean if @config.common.cache[:global]
        config.common.cache[:netboot].clean
        deploy_free(info)
        nil
      end

    end

    [info[:wid],info[:resources]]
  end

  def deploy_get(wid)
    error = nil
    ret = get_workflow(:deploy,wid) do |info|
      done = nil
      status = {}
      if info[:thread].alive?
        done = false
        info[:workflows].each_pair do |cluster,workflow|
          status[cluster] = workflow.status
        end
      else
        begin
          info[:thread].join
        rescue Exception => e
          error = e
        end
        done = true
        info[:done] = true
      end
      {
        :status => status,
        :time => (Time.now - info[:start_time]).round(2),
        :done => done,
      }
    end

    if error
      deploy_delete(wid)
      raise error
    end

    ret
  end

  def deploy_delete(wid)
    delete_workflow(:deploy,wid) do |info|
      info[:thread].kill if info[:thread].alive?
      info[:threads].each_value{|thread| thread.kill }
      info[:workflows].each_value{|workflow| workflow.kill }
      info[:database].disconnect if info[:database]
      info[:cached_files].each{|file| file.release } if info[:cached_files]

      deploy_free(info)
      GC.start
      { :wid => wid }
    end
  end

  def deploy_bindings(info)
    bind(:deploy,info,'output','/outputs') do |httpd,path|
      httpd.bind([:GET,:HEAD],path) do |request,method|
        deploy_output(info[:wid])
      end
    end

    bind(:deploy,info,'outputs','/outputs',info[:clusterlist]) do |httpd,path,cluster|
      httpd.bind([:GET,:HEAD],path) do |request,method|
        deploy_output(info[:wid],cluster)
      end
    end

    bind(:deploy,info,'state','/state') do |httpd,path|
      httpd.bind([:GET,:HEAD],path) do |request,method|
        deploy_state(info[:wid])
      end
    end

    if info[:debugger]
      bind(:deploy,info,'debug','/debugs') do |httpd,path|
        httpd.bind([:GET,:HEAD],path) do |request,method|
          deploy_debug(info[:wid])
        end
      end

      bind(:deploy,info,'debugs','/debugs',info[:nodelist]) do |httpd,path,node|
        httpd.bind([:GET,:HEAD],path) do |request,method|
          deploy_debug(info[:wid],node)
        end
      end
    end
  end

  def deploy_free(info)
    unbind(info)
    info[:environment].free if info[:environment]
    info[:workflows].each_value{|workflow| workflow.free }
    info[:output].free if info[:output]
    info[:debugger].free if info[:debugger]
    # ...
  end

  def deploy_output(wid,cluster=nil)
    get_workflow(:deploy,wid) do |info|
      if info[:workflows][cluster]
        info[:workflows][cluster].output.pop unless info[:workflows][cluster].done?
      else
        output = ''
        output << info[:output].pop
        info[:workflows].each_value do |workflow|
          output << workflow.output.pop unless workflow.done?
        end
        output
      end
    end
  end

  def deploy_debug(wid,node=nil)
    get_workflow(:deploy,wid) do |info|
      info[:debugger].pop(node) if info[:debugger] and !info[:done]
    end
  end

  def deploy_state(wid)
    get_workflow(:deploy,wid) do |info|
      info[:state].states
    end
  end

end
