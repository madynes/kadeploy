module Kadeploy

module Kaworkflow
  WORKFLOW_STATUS_CHECK_PITCH=1

  def work_init_exec_context(kind,ret)
    ret.config = nil
    ret.info = nil
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
    if [:deploy,:reboot].include?(kind)
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
      ret.timeout_reboot_classical = nil
    end
    ret
  end

  def work_free_exec_context(kind,context)
    context = free_exec_context(context)

    context.config = nil
    context.nodes.free if context.nodes
    context.nodes = nil
    context.nodelist = nil
    context.steps = []
    context.force = false
    context.breakpoint = nil
    context.custom_operations = nil
    context.verbose_level = nil
    context.debug = false
    context.output = nil
    context.outputfile = nil
    context.logger = nil
    context.loggerfile = nil
    if [:deploy,:reboot].include?(kind)
      context.pxe = nil
      context.client = nil
      context.environment = nil
      context.env_kind = nil
      context.block_device = nil
      context.deploy_part = nil
      context.key = nil
      context.boot_part = nil
      context.vlan_id = nil
      context.vlan_addr = nil
      context.timeout_reboot_classical = nil
    end

    context
  end

  def work_init_info(kind,cexec)
    hook = nil
    nodes = Nodes::NodeSet.new(0)
    cexec.nodes.duplicate(nodes)
    hook = cexec.config.common.send(:"end_of_#{kind.to_s}_hook").dup if cexec.hook
    {
      :wid => uuid(API.wid_prefix(kind)),
      :user => cexec.user,
      :start_time => Time.now,
      :end_time => nil,
      :done => false,
      :error => false,
      :thread => nil,
      :config => cexec.config,
      :nodelist => cexec.nodelist,
      :clusterlist => nodes.group_by_cluster.keys,
      :nodes => nodes,
      :state => Nodes::NodeState.new(),
      :database => database_handler(),
      :workflows => {},
      :threads => {},
      :outputfile => cexec.outputfile,
      :loggerfile => cexec.loggerfile,
      :hook => hook,
      :output => Debug::OutputControl.new(
        cexec.verbose_level || cexec.config.common.verbose_level,
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
      :cached_files => {:global=>[],:netboot=>[]},
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

  def work_prepare(kind,params,operation,context)
    context = run_wmethod(kind,:init_exec_context,context)
    operation ||= :create

    case operation
    when :create, :modify
      context.config = duplicate_config()
      parse_params(params) do |p|
        # Check nodelist
        context.nodes = p.parse('nodes',Array,:mandatory=>true,
          :type=>:nodeset, :errno=>APIError::INVALID_NODELIST)
        context.nodelist = context.nodes.make_array_of_hostname

        # Check existing rights on nodes by cluster
        kaerror(APIError::INVALID_RIGHTS) \
          unless context.rights.granted?(context.user,context.nodes,'')

        # Check custom breakpoint
        context.breakpoint = p.parse('breakpoint',String,:type=>:breakpoint,:kind=>kind)

        # Check custom microsteps
        context.custom_operations = p.parse('custom_operations',Hash,
          :type=>:custom_ops,:kind=>kind,:errno=>APIError::INVALID_CUSTOMOP)

        # Check force
        context.force = p.parse('force',nil,:toggle=>true)

        # Check verbose level
        context.verbose_level = p.parse('verbose_level',Fixnum,:range=>(1..5))

        # Check debug
        context.debug = p.parse('debug',nil,:toggle=>true)

        # Check hook
        context.hook = p.parse('hook',nil,:toggle=>true)

        # Loading OutputControl
        if context.config.common.dbg_to_file and !context.config.common.dbg_to_file.empty?
          context.outputfile = Debug::FileOutput.new(context.config.common.dbg_to_file,
            context.config.common.dbg_to_file_level)
        end

        if context.config.static[:logfile] and !context.config.static[:logfile].empty?
          context.loggerfile = Debug::FileOutput.new(context.config.static[:logfile])
        end

        if [:deploy,:reboot].include?(kind)
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
              vlan_hostname = "#{host}#{context.config.common.vlan_hostname_suffix}.#{domain}"
              vlan_hostname.gsub!('VLAN_ID', context.vlan_id)

              begin
                context.vlan_addr[hostname] = dns.getaddress(vlan_hostname).to_s
              rescue Resolv::ResolvError
                kaerror(APIError::INVALID_VLAN,"Cannot resolv #{vlan_hostname}")
              end
              kaerror(APIError::INVALID_VLAN,"Resolv error #{vlan_hostname}") if !context.vlan_addr[hostname] or context.vlan_addr[hostname].empty?
            end
            dns.close
            dns = nil
          end

          # Check PXE options
          p.parse('pxe',Hash) do |pxe|
            context.pxe = {}
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

            type = p.check(env['kind'],String,:values=>['anonymous','database'],
              :default=>'database')
            if type == 'database'
              p.check(env['user'],String,:errno=>APIError::INVALID_ENVIRONMENT)
              unless context.environment.load_from_db_context(
                context.database,
                env['name'],
                env['version'],
                env['user'],
                context.user,
                context.almighty_users
              ) then
                kaerror(APIError::INVALID_ENVIRONMENT,"the environment #{env['name']},#{env['version']} of #{env['user']} does not exist")
              end
            end
          end

          # Check reboot timeout
          p.parse('timeout_reboot_classical',String) do |timeout|
            begin
              eval("n=1; #{timeout}")
            rescue Exception => e
              kaerror(APIError::INVALID_OPTION,
                "the timeout is not a valid expression (#{e.message})")
            end
            context.timeout_reboot_classical = timeout
          end
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
          return (cexec.almighty_users.include?(cexec.user) \
            or cexec.user == info[:user])
        end
      end
    when :delete
      return false unless wid
      workflow_get(kind,wid) do |info|
        return (cexec.almighty_users.include?(cexec.user) \
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
    cexecdup = cexec.dup
    cexecdup.nodes = nil

    info[:thread] = Thread.new do
      begin
        context = {
          :wid => info[:wid].dup,
          :user => info[:user],
          #:nodelist => cexec.nodelist,
          #:nodes => cexec.nodes,
          :states => info[:state],
          :nodesets_id => Nodes::NodeSetId.new,
          :execution => cexecdup,
          :common => info[:config].common,
          :caches => info[:config].caches,
          :cluster => nil,
          :cluster_prefix => nil,

          :database => info[:database],

          :windows => @window_managers,
          :output => info[:output],
          :debugger => info[:debugger],
        }

        workflows = info[:workflows]

        # Cache the files
        begin
          GrabFile.grab_user_files(context,info[:cached_files],workflow_lock(kind,info[:wid]),kind)
        rescue KadeployError => ke
          info[:lock].synchronize do
            info[:nodes].set_state('aborted',nil,context[:database],context[:user])
          end
          raise ke
        end

        output = nil
        info[:lock].synchronize do
          # Set clusters IDs
          clusters = info[:nodes].group_by_cluster
          if clusters.size > 1
            clid = 1
          else
            clid = 0
          end

          # Run a Workflow by cluster
          clusters.each_pair do |cluster,nodeset|
            context[:cluster] = info[:config].clusters[cluster]
            if clusters.size > 1
              if context[:cluster].prefix.empty?
                context[:cluster_prefix] = "c#{clid}"
                clid += 1
              else
                context[:cluster_prefix] = context[:cluster].prefix.dup
              end
              context[:nodesets_id] = context[:nodesets_id].dup #Avoid to link the counter of different clusters, because they have different prefixs.
            else
              context[:cluster_prefix] = ''
            end

            info[:outputfile].prefix = "#{context[:wid]}|#{info[:user]} -> " if info[:outputfile]
            context[:output] = Debug::OutputControl.new(
              context[:execution].verbose_level || info[:config].common.verbose_level,
              info[:outputfile],
              context[:cluster_prefix]
            )
            context[:logger] = Debug::Logger.new(
              nodeset.make_array_of_hostname,
              info[:user],
              context[:wid],
              Time.now,
              (info[:environment] ? "#{info[:environment].name}:#{info[:environment].version.to_s}" : nil),
              (info[:environment] and info[:environment].id < 0),
              info[:loggerfile],
              (info[:config].common.log_to_db ? context[:database] : nil)
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
              output.push(0,"  #{Debug.prefix(workflow.context[:cluster_prefix])}: #{workflow.context[:cluster].name}")
            end
            output.push(0,"---")
          end

          # Run every workflows
          workflows.each_value{ |wf| info[:threads][wf] = wf.run! }
        end # synchronize

        # Wait for cleaners to be started
        workflows.each_value{ |wf| sleep(0.2) until (wf.cleaner or wf.done?) }

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

        info[:lock].synchronize do
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
          Nodes::sort_list(info[:nodes_ok])
          Nodes::sort_list(info[:nodes_ko])

          if output
            info[:workflows].each_value do |workflow|
              output.write(workflow.output.pop) unless workflow.output.empty?
            end
          end

          info[:done] = true
        end # synchronize

        yield(info) if block_given?

        # Clean everything
        info[:lock].synchronize do
          free_exec_context(context[:execution])
          run_wmethod(kind,:free,info)
        end

      rescue Exception => e
        info[:lock].synchronize do
          info[:error] = true
          run_wmethod(kind,:kill,info)
          run_wmethod(kind,:free,info)
        end
        raise e
      ensure
        run_wmethod(kind,:end_hook,info)
      end
    end

    { :wid => info[:wid], :resources => info[:resources] }
  end

  # TODO: implement it
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
        done = false
      end

      if info[:error]
        error = true
        done = true
      end

      ret = {
        :wid => info[:wid],
        :user => info[:user],
        :done => done,
        :error => error,
        :start_time => info[:start_time].to_i,
      }

      if cexec.almighty_users.include?(cexec.user) or cexec.user == info[:user]
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
              ok = []
              ok += status[:OK].make_array_of_hostname if status[:OK].is_a?(Nodes::NodeSet)
              ko = []
              ko += status[:KO].make_array_of_hostname if status[:KO].is_a?(Nodes::NodeSet)
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

    if wid
      workflow_get(kind,wid) do |info|
        get_status.call(info)
      end
    else
      ret = []
      workflow_list(kind) do |info|
        ret << get_status.call(info)
      end
      ret
    end
  end

  def work_delete(kind,cexec,wid)
    workflow_delete(kind,wid) do |info|
      run_wmethod(kind,:delete!,cexec,info)
    end
  end

  def work_delete!(kind,cexec,info)
    run_wmethod(kind,:kill,info)
    run_wmethod(kind,:free,info)
    info[:output].free if info[:output]
    info.delete(:output)
    info[:debugger].free if info[:debugger]
    info.delete(:debugger)
    info[:state].free if info[:state]
    info.delete(:state)
    info.delete(:environment)
    info.delete(:thread)
    # ...

    { :wid => info[:wid] }
  end


  def work_kill(kind,info)
    unless info[:freed]
      info[:thread].kill if info[:thread] and info[:thread].alive? and info[:thread] != Thread.current
      info[:threads].each_value{|thread| thread.kill} if info[:threads]
      if info[:workflows] and !info[:done]
        info[:workflows].each_value do |workflow|
          begin
            workflow.kill
          rescue KadeployError
          end
        end
      end
      release_cache(info)
    end
  end
  def release_cache(info)
    if info[:cached_files]
      if info[:config].caches[:global]
        info[:config].caches[:global].release(info[:wid])
        info[:config].caches[:global].clean
      end
      if info[:config].caches[:netboot]
        info[:config].caches[:netboot].release(info[:wid])
        info[:config].caches[:netboot].clean
      end
      info.delete(:cached_files)
    end
  end

  def work_free(kind,info)
    unless info[:freed]
      info[:freed] = true
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

      info[:outputfile].free if info[:outputfile]
      info.delete(:outputfile)
      info[:loggerfile].free if info[:loggerfile]
      info.delete(:loggerfile)

      info[:database].free if info[:database]
      info.delete(:database)

      release_cache(info)

      info[:config].free
      info.delete(:config)

      info.delete(:resources)
    end
  end

  def work_get_logs(kind,cexec,wid,cluster=nil)
    workflow_get(kind,wid) do |info|
      # check if already done
      break if info[:error]
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
      break if info[:error]
      error_not_found! if (node and !info[:nodelist].include?(node)) or !info[:debugger]

      info[:debugger].pop(node)
    end
  end

  def work_get_state(kind,cexec,wid)
    workflow_get(kind,wid) do |info|
      break if info[:error]
      info[:state].states
    end
  end

  def work_get_status(kind,cexec,wid)
    workflow_get(kind,wid) do |info|
      break if info[:error]
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
      break if !info[:error]
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

  def work_end_hook(kind,info)
    if info[:hook]
      cmd = info[:hook].gsub('WORKFLOW_ID',info[:wid])
      run = Execute[cmd]
      begin
        Timeout::timeout(20) do
          run.run!(:stdin=>false,:stdout=>false,:stderr=>false)
          run.wait(:checkstatus=>false)
        end
        if run.status.exitstatus != 0
          STDERR.puts("[#{Time.now}] The hook command has returned non-null status: #{run.status.exitstatus} (#{cmd})")
          STDERR.flush
        end
      rescue Timeout::Error
        STDERR.puts("[#{Time.now}] The hook command has expired (#{cmd})")
        STDERR.flush
      rescue Exception => ex
        STDERR.puts "[#{Time.now}] #{ex}"
        STDERR.puts ex.backtrace
        STDERR.flush
      end
    end
  end
end

end

