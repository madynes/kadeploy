module Kadeploy

module Kaworkflow
  WORKFLOW_STATUS_CHECK_PITCH=1

  def work_init_exec_context(kind)
    ret = init_exec_context()
    ret.info = nil
    ret.database = nil
    ret.rights = nil
    ret.nodes = nil
    ret.nodelist = nil
    ret.steps = []
    ret.force = false
    ret.breakpoint = nil
    ret.custom_operations = nil
    ret.verbose_level = nil
    ret.debug = false
    ret.output = nil
    ret.outputfile = nil
    ret.logger = nil
    ret.loggerfile = nil
###
    ret.pxe = nil
    ret.client = nil
    ret.environment = nil
    ret.env_kind = nil
    ret.block_device = nil
    ret.deploy_part = nil
    ret.key = nil
    ret.boot_part = nil
    ret.vlan_id = nil
    ret.vlan_addr = nil
    ret
  end

  def work_init_info(kind,cexec,prefix='')
    {
      :wid => uuid(prefix),
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
      :workflows => {},
      :threads => {},
      :outputfile => cexec.outputfile,
      :loggerfile => cexec.loggerfile,
      :output => Debug::OutputControl.new(
        cexec.verbose_level || config.common.verbose_level,
        cexec.outputfile,
        ''
      ),
      :debugger => (cexec.debug ? Debug::DebugControl.new() : nil),
      :nodes_ok => [],
      :nodes_ko => [],
      :resources => {},
      :bindings => [],
      :freed => false,
###
      :cached_files => nil,
      :environment => cexec.environment,
    }
  end

  def work_init_resources(kind,cexec)
    info = cexec.info
    bind(kind,info,'log','/logs')
    bind(kind,info,'logs','/logs',info[:clusterlist])
    bind(kind,info,'state','/state')
    bind(kind,info,'status','/status')
    bind(kind,info,'error','/error')

    if info[:debugger]
      bind(kind,info,'debug','/debugs')
      bind(kind,info,'debugs','/debugs',info[:nodelist])
    end
  end

  def work_prepare(kind,params,operation=:create)
    context = run_wmethod(kind,:init_exec_context)

    # Check user
    parse_params_default(params,context)

    case operation
    when :create, :modify
      # Check database
      context.database = database_handler()

      # Check rights
      context.rights = rights_handler(context.database)

      parse_params(params) do |p|
        # Check nodelist
        context.nodes = p.parse('nodes',Array,:mandatory=>true,
          :type=>:nodeset, :errno=>APIError::INVALID_NODELIST)
        context.nodelist = context.nodes.make_array_of_hostname

        # Check existing rights on nodes by cluster
        kaerror(APIError::INVALID_RIGHTS) \
          unless context.rights.granted?(context.user,context.nodes,'')

        # Check custom microsteps
        context.custom_operations = p.parse('custom_operations',Hash,
          :type=>:custom_ops,:errno=>APIError::INVALID_CUSTOMOP)

        # Check custom automata
        context.steps = p.parse('automata',Hash,:type=>:custom_automata)

        # Check force
        context.force = p.parse('force',nil,:toggle=>true)

        # Check verbose level
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

###
        # Check client
        context.client = p.parse('client',String,:type=>:client)

        # authorized_keys file
        context.key = p.parse('ssh_authorized_keys',String)

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

        # Check PXE options
        p.parse('pxe',Hash) do |pxe|
          context.pxe[:profile] = p.check(pxe['profile'],String)

          p.check(pxe['singularities'],Hash) do |singularities|
            p.check(singularities.keys,Array,:type=>:nodeset,
              :errno=>APIError::INVALID_NODELIST)
            context.pxe[:singularities] = singularities
          end

          context.pxe[:files] = p.check(pxe['files'],Array)
        end

        # Check partition
        context.block_device = p.parse('block_device',String)
        if context.block_device
          context.deploy_part = p.parse('deploy_partition',String,:emptiable=>true)
        else
          context.block_device = ''
          context.deploy_part = p.parse('deploy_partition',String,:default=>'')
        end

        # Check Database Environment
        env = p.parse('environment',Hash)
        if env
          context.environment = Environment.new
          p.check(env['name'],String,:mandatory=>true)

          kind = p.check(env['kind'],String,:values=>['anonymous','database'],
            :mandatory=>true)
          if kind == 'database'
            p.check(env['user'],String,:mandatory=>true,
              :errno=>APIError::INVALID_ENVIRONMENT)
            unless context.environment.load_from_db(
              context.database,
              env['name'],
              env['version'],
              env['user'],
              env['user'] == context.user,
              env['user'].nil?
            ) then
              kaerror(APIError::INVALID_ENVIRONMENT,"the environment #{env['name']},#{env['version']} of #{env['user']} does not exist")
            end
          end
        end

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
      end

    when :get
    when :delete
    else
      raise
    end

    context.info = run_wmethod(kind,:init_info,context) if operation == :create

    context
  end

  def work_rights?(kind,cexec,operation,names,wid=nil,*args)
    case operation
    when :create,:modify
    when :get
      if wid and names
        workflow_get(kind,wid) do |info|
          return (config.common.almighty_env_users.include?(cexec.user) \
            or cexec.user == info[:user])
        end
      end
    when :delete
      return false unless wid
      workflow_get(kind,wid) do |info|
        return (config.common.almighty_env_users.include?(cexec.user) \
          or cexec.user == info[:user])
      end
    else
      raise
    end

    return true
  end

  def work_create(kind,cexec)
    info = cexec.info
    workflow_create(kind,info[:wid],info)
    run_wmethod(kind,:init_resources,cexec)

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

      # Cache the files
      begin
        info[:cached_files] = GrabFile.grab_user_files(context)
      rescue KadeployError => ke
        info[:nodes].set_state('aborted',nil,cexec.database,cexec.user)
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

        workflow = Workflow.const_get("#{kind.to_s.capitalize}").new(nodeset,context.dup)

        workflows[cluster] = workflow
      end

      output = info[:output]

      # Print debug
      if clusters.size > 1 and output
        output.push(0,"---")
        output.push(0,"Clusters involved in the operation:")
        workflows.each_value do |workflow|
          output.push(0,"  #{Debug.prefix(workflow.context[:cluster].prefix)}: #{workflow.context[:cluster].name}")
        end
        output.push(0,"---")
      end

      # Run every workflows
      workflows.each_value{ |wf| info[:threads][wf] = wf.run! }

      # Wait for cleaners to be started
      workflows.each_value{ |wf| sleep(0.2) until (wf.cleaner) }

      # Wait for operation to end
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
        sleep(WORKFLOW_STATUS_CHECK_PITCH)
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
      run_wmethod(kind,:free,info)
    end

    { :wid => info[:wid], :resources => info[:resources] }
  end

  def work_modify(*args)
    error_invalid!
  end

  def work_get(kind,cexec,wid=nil)
    get_status = Proc.new do |info|
      done = nil
      error = false
      if info[:done]
        done = true
      else
        if !info[:thread].alive?
          done = true
          error = true
          run_wmethod(kind,:kill,info)
          run_wmethod(kind,:free,info)
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
        if info[:environment]
          ret[:environment] = {
            :id => info[:environment].id,
            :user => info[:environment].user,
            :name => info[:environment].name,
            :version => info[:environment].version,
          }
        end

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

    workflow_get(kind,wid) do |infos|
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

  def work_delete(kind,cexec,wid)
    workflow_delete(kind,wid) do |info|
      run_wmethod(kind,:kill,info)
      run_wmethod(kind,:free,info)
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

  def work_kill(kind,info)
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
      info.delete(:cached_files)
    end
  end

  def work_free(kind,info)
    unless info[:freed]
      info[:nodes].free if info[:nodes]
      info.delete(:nodes)

      info[:clusterlist].clear if info[:clusterlist]
      info.delete(:clusterlist)

      if info[:environment]
        env = OpenStruct.new
        env.user = info[:environment].user
        env.name = info[:environment].name
        env.version = info[:environment].version
        info[:environment].free if info[:environment]
        info[:environment] = env
      end

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

      config.common.cache[:global].clean if @config.common.cache[:global]
      config.common.cache[:netboot].clean

      info.delete(:resources)
      # ...
      info[:freed] = true
    end
  end

  def work_get_logs(kind,cexec,wid,cluster=nil)
    workflow_get(kind,wid) do |info|
      # check if already done
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

  def work_get_debugs(kind,cexec,wid,node=nil)
    workflow_get(kind,wid) do |info|
      break if !info[:done] and !info[:thread].alive? # error
      error_not_found! if (node and !info[:nodelist].include?(node)) or !info[:debugger]

      info[:debugger].pop(node)
    end
  end

  def work_get_state(kind,cexec,wid)
    workflow_get(kind,wid) do |info|
      break if !info[:done] and !info[:thread].alive? # error
      info[:state].states
    end
  end

  def work_get_status(kind,cexec,wid)
    workflow_get(kind,wid) do |info|
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

  def work_get_error(kind,cexec,wid)
    workflow_get(kind,wid) do |info|
      break if info[:done] or info[:thread].alive?
      begin
        info[:thread].join
        info[:threads].each_value{|thr| thr.join unless thr.alive?} if info[:threads]
        nil
      rescue Exception => e
        run_wmethod(kind,:free,info)
        raise e
      end
    end
  end
end

end

