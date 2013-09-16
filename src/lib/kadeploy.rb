require 'uri'

require 'grabfile'
require 'workflow'

module Kadeploy
DEPLOY_STATUS_CHECK_PITCH=1

module Kadeploy
  def deploy_init_exec_context()
    ret = init_exec_context()
    ret.nodes = nil
    ret.nodelist = nil
    ret.environment = nil
    ret.env_kind = nil
    ret.block_device = String.new
    ret.deploy_part = String.new
    ret.boot_part = nil
    ret.verbose_level = nil
    ret.debug = false
    ret.key = String.new
    ret.reformat_tmp = nil
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

  def deploy_init_info(cexec)
    {
      :wid => uuid('D-'),
      :user => cexec.user,
      :start_time => Time.now,
      :end_time => nil,
      :done => false,
      :thread => nil,
      :nodelist => cexec.nodelist,
      :clusterlist => cexec.nodes.group_by_cluster.keys,
      :nodes => cexec.nodes,
      :state => Nodes::NodeState.new(),
      :database => cexec.database,
      :environment => cexec.environment,
      :workflows => {},
      :threads => {},
      :cached_files => nil,
      :outputfile => cexec.outputfile,
      :loggerfile => cexec.loggerfile,
      :output => Debug::OutputControl.new(
        cexec.verbose_level || config.common.verbose_level,
        cexec.outputfile,
        ''
      ),
      :debugger => (cexec.debug ? Debug::DebugControl.new() : nil),
      :resources => {},
      :bindings => [],
      :freed => false,

      :nodes_ok => [],
      :nodes_ko => [],
    }
  end

  def deploy_init_resources(cexec)
    info = cexec.info
    bind(:deploy,info,'log','/logs')
    bind(:deploy,info,'logs','/logs',info[:clusterlist])
    bind(:deploy,info,'state','/state')
    bind(:deploy,info,'status','/status')
    bind(:deploy,info,'error','/error')

    if info[:debugger]
      bind(:deploy,info,'debug','/debugs')
      bind(:deploy,info,'debugs','/debugs',info[:nodelist])
    end
  end

  def deploy_prepare(params,operation=:create)
    context = deploy_init_exec_context()

    # Check user
    parse_params_default(params,context)

    case operation
    when :create
      # Check database
      context.database = database_handler()

      #Rights check
      rights = rights_handler(context.database)

      parse_params(params) do |p|
        # Check client
        context.client = p.parse('client',String,:type=>:client)

        # authorized_keys file
        context.key = p.parse('ssh_authorized_keys',String)

        # Check nodelist
        context.nodes = p.parse('nodes',Array,:mandatory=>true,
          :type=>:nodeset, :errno=>APIError::INVALID_NODELIST)
        context.nodelist = context.nodes.make_array_of_hostname

        # Check VLAN
        p.parse('vlan',String) do |vlan|
          context.vlan_id = vlan
          dns = Resolv::DNS.new
          context.vlan_addr = {}
          context.nodelist.each do |hostname|
            host,domain = hostname.split('.',2)
            vlan_hostname = "#{host}#{config.common.vlan_hostname_suffix}"\
              ".#{domain}".gsub!('VLAN_ID', context.vlan_id)
            begin
              context.vlan_addr = dns.getaddress(vlan_hostname).to_s
            rescue Resolv::ResolvError
              kaerror(APIError::INVALID_VLAN,"Cannot resolv #{vlan_hostname}")
            end
          end
          dns.close
          dns = nil
        end

        # Check PXE
        p.parse('pxe',Hash) do |pxe|
          context.pxe_profile_msg = p.check(pxe['profile'],String)
          # TODO: check singularities
          context.pxe_profile_singularities = p.check(pxe['singularities'],String)
          p.parse(pxe['files'],Array) do |files|
            context.pxe_upload_files = files
          end
        end

        # TODO: check custom operations

        # Check Environment
        env = p.parse('environment',Hash,:mandatory=>true)
        context.environment = Environment.new

        kind = p.check(env['kind'],String,:values=>['anonymous','database'])

        case kind
        when 'anonymous'
          env.delete('kind')
          unless context.environment.load_from_desc(
            env,
            config.common.almighty_env_users,
            context.user,
            context.client
          ) then
            kaerror(APIError::INVALID_ENVIRONMENT,'the environment cannot be loaded from the description you specified')
          end
          context.env_kind = :anon
        when 'database'
          p.check(env['user'],String,:mandatory=>true,:errno=>APIError::INVALID_ENVIRONMENT)

          unless context.environment.load_from_db(
            context.database,
            env['name'],
            env['version'],
            env['user'],
            env['user'] == context.user,
            env['user'].nil?
          ) then
            kaerror(APIError::INVALID_ENVIRONMENT,"the environment #{env['name']},#{env['version']}/#{env['user']} does not exist")
          end
          context.env_kind = :db
        else
          kaerror(APIError::INVALID_ENVIRONMENT,'invalid \'kind\' field')
        end
        env = nil

        # Multi-partitioned archives hack
        if context.environment.multipart
          params['block_device'] = context.environment.options['block_device']
          params['deploy_partition'] = context.environment.options['deploy_part']
        end

        #The rights must be checked for each cluster if the node_list contains nodes from several clusters
        context.nodes.group_by_cluster.each_pair do |cluster, nodes|
          part = (
            p.parse('block_device',String,
              :default=>config.cluster_specific[cluster].block_device) \
            + p.parse('deploy_partition',String,:emptiable=>true,
              :default=>config.cluster_specific[cluster].deploy_part)
          )
          kaerror(APIError::INVALID_RIGHTS,"deployment on partition #{part}") \
            unless rights.granted?(context.user,nodes,part)
        end

        # Check the boot partition
        context.boot_part = p.parse('boot_partition',Fixnum)

        # Check disable options
        context.disable_bootloader_install = p.parse('disable_bootloader_install',nil,:toggle=>true)
        context.disable_disk_partitioning = p.parse('disable_disk_partitioning',nil,:toggle=>true)

        # Check rights on multipart environement
        if context.environment.multipart
          context.environment.options['partitions'].each do |part|
            unless rights.granted?(context.user,context.nodes,part['device'])
              kaerror(APIError::INVALID_RIGHTS,"deployment on partition #{part['device']}")
            end
          end
        end

        # Check reformat tmp partition
        context.reformat_tmp = p.parse('reformat_tmp_partition',String)

        # Check reboot timeouts
        p.parse('timeout_reboot_classical',String) do |timeout|
          begin
            eval("n=1; #{timeout}")
          rescue Exception => e
            kaerror(APIError::INVALID_OPTION,
              "the timeout is not a valid expression (#{e.message})")
          end
          context.timeout_reboot_classical = timeout
        end
        p.parse('timeout_reboot_kexec',String) do |timeout|
          begin
            eval("n=1; #{timeout}")
          rescue
            kaerror(APIError::INVALID_OPTION,
              "the timeout is not a valid expression (#{e.message})")
          end
          context.timeout_reboot_kexec= timeout
        end

        # Check force
        context.ignore_nodes_deploying = p.parse('force',nil,:toggle=>true)

        # Check debug
        context.verbose_level = p.parse('verbose_level',Fixnum,:range=>(1..5))

        # Check debug
        context.debug = p.parse('debug',nil,:toggle=>true)

        # Loading OutputControl
        if config.common.dbg_to_file and !config.common.dbg_to_file.empty?
          context.outputfile = Debug::FileOutput.new(config.common.dbg_to_file,
            config.common.dbg_to_file_level)
        end

        if config.common.log_to_file and !config.common.log_to_file.empty?
          context.loggerfile = Debug::FileOutput.new(config.common.log_to_file)
        end
      end
    when :get
    when :delete
    else
      raise
    end

    context
  end

  def deploy_rights?(cexec,operation,names,wid=nil,*args)
    case operation
    when :create
    when :get
      if wid and names
        workflow_get(:deploy,wid) do |info|
          return (config.common.almighty_env_users.include?(cexec.user) \
            or cexec.user == info[:user])
        end
      end
    when :delete
      return false unless wid
      workflow_get(:deploy,wid) do |info|
        return (config.common.almighty_env_users.include?(cexec.user) \
          or cexec.user == info[:user])
      end
    else
      raise
    end

    return true
  end

  def deploy_create(cexec)
    info = cexec.info
    workflow_create(:deploy,info[:wid],info)

    info[:thread] = Thread.new do
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
        :output => info[:output],
        :debugger => info[:debugger],
      }

      workflows = info[:workflows]

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

        workflow = Workflow::Kadeploy.new(nodeset,context.dup)

        workflows[cluster] = workflow
      end

      output = info[:output]

      # Print debug
      if clusters.size > 1 and output
        output.push(0,"---")
        output.push(0,"Clusters involved in the deployment:")
        workflows.each_value do |workflow|
          output.push(0,"  #{Debug.prefix(workflow.context[:cluster].prefix)}: #{workflow.context[:cluster].name}")
        end
        output.push(0,"---")
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

      info[:end_time] = Time.now

      # Print debug
      workflows.each_value do |workflow|
      #  clname = workflow.context[:cluster].name
      #  output.push(0,"")
        unless workflow.nodes_brk.empty?
          info[:nodes_ok] += workflow.nodes_brk.make_array_of_hostname
        end

        unless workflow.nodes_ok.empty?
          info[:nodes_ok] += workflow.nodes_ok.make_array_of_hostname
        end

        unless workflow.nodes_ko.empty?
          info[:nodes_ko] += workflow.nodes_ko.make_array_of_hostname
        end
      end

      if output
        info[:workflows].each_value do |workflow|
          output.write(workflow.output.pop) unless workflow.output.empty?
        end
      end

      info[:done] = true

      # Clean everything
      info[:cached_files].each{|file| file.release } if info[:cached_files]
      config.common.cache[:global].clean if @config.common.cache[:global]
      config.common.cache[:netboot].clean
      deploy_free(info)
    end

    { :wid => info[:wid], :resources => info[:resources] }
  end

  def deploy_get(cexec,wid=nil)
    get_status = Proc.new do |info|
      done = nil
      error = false
      if info[:done]
        done = true
      else
        if !info[:thread].alive?
          done = true
          error = true
          deploy_kill(info)
          deploy_free(info)
        else
          done = false
        end
      end

      ret = {
        :id => info[:wid],
        :user => info[:user],
        :done => done,
        :error => error,
      }

      if config.common.almighty_env_users.include?(cexec.user) or cexec.user == info[:user]
        ret[:environment] = {
          :user => info[:environment].user,
          :name => info[:environment].name,
          :version => info[:environment].version,
          #:kind => anon/database
        }

        if !error
          logs = !info[:output].empty?
          if !logs and info[:workflows]
            info[:workflows].each_value do |workflow|
              if !workflow.done? and !workflow.output.empty?
                logs = true
                break
              end
            end
          end
          ret[:logs] = logs

          ret[:debugs] = !info[:debugger].empty? if info[:debugger]

          if done
            ret[:nodes] = {
              :ok => info[:nodes_ok],
              :ko => info[:nodes_ko],
            }
          else
            ret[:nodes] = {
              :ok => [],
              :ko => [],
              :processing => [],
            }
            info[:workflows].each_value do |workflow|
              status = workflow.status
              ok = status[:OK].make_array_of_hostname rescue []
              ko = status[:KO].make_array_of_hostname rescue []
              nodes = workflow.nodes.make_array_of_hostname
              nodes.each do |node|
                if ok.include?(node)
                  ret[:nodes][:ok] << node
                elsif ko.include?(node)
                  ret[:nodes][:ko] << node
                else
                  ret[:nodes][:processing] << node
                end
              end
            end
          end
        end

        ret[:time] = ((info[:end_time]||Time.now) - info[:start_time]).round(2)
        #ret[:states] = info[:state].states
      else
        ret[:nodes] = info[:nodelist]
      end

      ret
    end

    workflow_get(:deploy,wid) do |infos|
      if infos.is_a?(Array)
        ret = []
        infos.each do |info|
          ret << get_status.call(info)
        end
        ret
      else
        get_status.call(infos)
      end
    end
  end

  def deploy_delete(cexec,wid)
    workflow_delete(:deploy,wid) do |info|
      deploy_kill(info)
      deploy_free(info)
      info[:output].free if info[:output]
      info[:output] = nil
      info[:debugger].free if info[:debugger]
      info[:debugger] = nil
      info[:environment] = nil
      # :thread
      # ...

      GC.start
      { :wid => info[:wid] }
    end
  end

  def deploy_kill(info)
    unless info[:freed]
      info[:thread].kill if info[:thread] and info[:thread].alive?
      info[:threads].each_value{|thread| thread.kill} if info[:threads]
      if info[:workflows]
        info[:workflows].each_value do |workflow|
          begin
            workflow.kill
          rescue KadeployError
          end
        end
      end
      info[:database].disconnect if info[:database]
      info[:cached_files].each{|file| file.release} if info[:cached_files]
    end
  end

  def deploy_free(info)
    unless info[:freed]
      info[:nodes].free if info[:nodes]
      info.delete(:nodes)

      info[:clusterlist].clear if info[:clusterlist]
      info.delete(:clusterlist)

      env = OpenStruct.new
      env.user = info[:environment].user
      env.name = info[:environment].name
      env.version = info[:environment].version
      info[:environment].free if info[:environment]
      info[:environment] = env

      info[:workflows].each_value{|workflow| workflow.free } if info[:workflows]
      info.delete(:workflows)
      info[:threads].clear if info[:threads]
      info.delete(:threads)
      #info[:thread] = nil

      info[:outputfile].free if info[:outputfile]
      info.delete(:outputfile)
      info[:loggerfile].free if info[:loggerfile]
      info.delete(:loggerfile)

      #info[:output].free if info[:output]
      #info.delete(:output)
      #info[:debugger].free if info[:debugger]
      #info.delete(:debugger)
      info[:state].free if info[:state]
      info.delete(:state)

      info[:database].free if info[:database]
      info.delete(:database)

      info[:cached_files].each{|file| file.release } if info[:cached_files]
      info.delete(:cached_files)

      info.delete(:resources)
      # ...
      info[:freed] = true
    end
  end

  def deploy_get_logs(cexec,wid,cluster=nil)
    # check if already done
    workflow_get(:deploy,wid) do |info|
      break if !info[:done] and !info[:thread].alive? # error
      error_not_found! if info[:workflows] and cluster and !info[:workflows][cluster]

      if info[:workflows] and info[:workflows][cluster]
        info[:workflows][cluster].output.pop unless info[:workflows][cluster].done?
      else
        log = ''
        log << info[:output].pop
        if info[:workflows]
          info[:workflows].each_value do |workflow|
            log << workflow.output.pop unless workflow.done?
          end
        end
        log
      end
    end
  end

  def deploy_get_debugs(cexec,wid,node=nil)
    workflow_get(:deploy,wid) do |info|
      break if !info[:done] and !info[:thread].alive? # error
      error_not_found! if (node and !info[:nodelist].include?(node)) or !info[:debugger]

      info[:debugger].pop(node)
    end
  end

  def deploy_get_state(cexec,wid)
    workflow_get(:deploy,wid) do |info|
      break if !info[:done] and !info[:thread].alive? # error
      info[:state].states
    end
  end

  def deploy_get_status(cexec,wid)
    workflow_get(:deploy,wid) do |info|
      break if !info[:done] and !info[:thread].alive? # error
      ret = {}
      if info[:thread] and info[:thread].alive?
        info[:workflows].each_pair do |cluster,workflow|
          ret[cluster] = workflow.status
        end
      end
      ret
    end
  end

  def deploy_get_error(cexec,wid)
    workflow_get(:deploy,wid) do |info|
      break if info[:done] or info[:thread].alive?
      # TODO: join each workflow thread
      begin
        info[:thread].join
      rescue Exception => e
        deploy_free(info)
        raise e
      end
    end
  end
end

end
