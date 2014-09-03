require 'thread'
require 'securerandom'
require 'ostruct'
require 'base64'


module Kadeploy

class KadeployServer
  include Kaworkflow
  include Kadeploy
  include Kareboot
  include Kapower
  include Kaenvs
  include Kastats
  include Karights
  include Kanodes
  include Kaconsole

  attr_reader :host, :port, :secure, :local, :cert, :private_key, :logfile, :window_managers, :httpd, :ssh_private_key
  attr_writer :shutdown

  def initialize()
    @config = load_config()
    @config_lock = Mutex.new
    @host = @config.static[:host]
    @port = @config.static[:port]
    @secure = @config.static[:secure]
    @local = @config.static[:local]
    @private_key = @config.static[:private_key]
    @cert = @config.static[:cert]
    @logfile = @config.static[:logfile]
    @ssh_private_key = @config.static[:ssh_private_key]
    check_database()
    @window_managers = {
      :reboot => WindowManager.new(
        @config.static[:reboot_window],
        @config.static[:reboot_window_sleep_time]
      ),
      :check => WindowManager.new(
        @config.static[:nodes_check_window],
        1
      ),
    }
    @workflows_locks = {
      :deploy => Mutex.new,
      :reboot => Mutex.new,
      :power => Mutex.new,
      :console => Mutex.new,
    }
    @workflows_info = {
      :deploy => {},
      :reboot => {},
      :power => {},
      :console => {},
    }
    @httpd = nil
    @shutdown = false
  end

  def kill
    workflows_kill(get_nodes())
  end

  def load_config(caches=nil)
    ret = nil
    begin
      ret = Configuration::Config.new(nil,caches)
    rescue KadeployError, ArgumentError => e
      kaerror(APIError::BAD_CONFIGURATION,e.message)
    end
    ret
  end

  def reload_config()
    @config_lock.synchronize do
      newconfig = load_config(@config.caches)
      if @config.static_values == newconfig.static_values
        oldconfig = @config
        @config = newconfig
        oldconfig.free
      else
        kaerror(APIError::BAD_CONFIGURATION,'Some static parameters were modified, please restart the server')
      end
    end
  end

  def cfg()
    @config_lock.synchronize do
      if block_given?
        yield(@config)
      else
        @config
      end
    end
  end

  def duplicate_config()
    cfg().duplicate()
  end

  def database_handler()
    cfg() do |conf|
      db = Database::DbFactory.create(conf.common.db_kind)
      unless db.connect(
        conf.common.deploy_db_host.dup,
        conf.common.deploy_db_login.dup,
        conf.common.deploy_db_passwd.dup,
        conf.common.deploy_db_name.dup
      ) then
        kaerror(APIError::DATABASE_ERROR,'Cannot connect to the database')
      end
      db
    end
  end

  def rights_handler(db)
    Rights::Factory.create(cfg.common.rights_kind.dup,db)
  end

  def check_database()
    begin
      database_handler().free
    rescue
      kaerror(APIError::DATABASE_ERROR,'Cannot connect to the database')
    end
  end

  def kaerror(errno,msg='')
    raise KadeployError.new(errno,nil,msg)
  end

  def error_not_found!(msg=nil)
    raise HTTPd::NotFoundError.new(msg)
  end

  def error_unauthorized!(msg=nil)
    headers = nil
    if cfg.static[:auth][:http_basic]
      headers = {'WWW-Authenticate' => "Basic realm=\"#{cfg.static[:auth][:http_basic].realm}\""}
    end
    raise HTTPd::UnauthorizedError.new(msg,headers)
  end

  def error_forbidden!(msg=nil)
    raise HTTPd::ForbiddenError.new(msg)
  end

  def error_invalid!(msg=nil)
    raise HTTPd::InvalidError.new(msg)
  end

  def error_unavailable!(msg=nil)
    raise HTTPd::UnavailableError.new(msg)
  end

  def uuid(prefix='')
    "#{prefix}#{SecureRandom.uuid}"
  end

  def bind(kind,info,resource,path=nil,multi=nil)
    if @httpd
      instpath = File.join(info[:wid],path||'')
      unless multi
        path = API.path(kind,instpath)
        info[:resources][resource] = API.ppath(kind,'/',instpath)
        if block_given?
          yield(@httpd,path)
          info[:bindings] << path
        end
      else
        info[:resources][resource] = {}
        multi.each do |res|
          minstpath = File.join(instpath,res)
          path = API.path(kind,minstpath)
          info[:resources][resource][res] = HTTP::Client.path_params(
            API.ppath(kind,'/',minstpath),{:user=>info[:user]})
          if block_given?
            yield(@httpd,path,res)
            info[:bindings] << path
          end
        end
      end
    else
      raise
    end
  end

  def unbind(info)
    if @httpd
      info[:bindings].each do |path|
        @httpd.unbind(path)
      end
    else
      raise
    end
  end

  def init_exec_context(user)
    raise if !user or user.empty?
    ret = OpenStruct.new
    ret.user = user.dup
    ret.database = database_handler()
    ret.rights = rights_handler(ret.database)
    ret.almighty_users = cfg.common.almighty_env_users.dup
    ret.info = nil
    ret.dry_run = nil
    ret
  end

  def free_exec_context(context)
    context.database.free if context.database
    context.almighty_users.clear if context.almighty_users
    context.almighty_users = nil
    context.database = nil
    context.rights = nil
    context.info = nil
    context.dry_run = nil
    context
  end

  def wipe_exec_context(context)
    #context.marshal_dump.keys.each do |name|
    #  obj = context.send(name.to_sym)
    #  obj.free if obj.respond_to?(:free)
    #  obj.clear if obj.respond_to?(:clear)
    #  context.delete_field(name)
    #end
  end

  def parse_params_default(params,context)
    parse_params(params) do |p|
      context.dry_run = p.parse('dry_run',nil,:toggle=>true)
    end
  end

  def parse_params(params)
    parser = nil
    cfg(){ |conf| parser = ParamsParser.new(params,conf) }
    yield(parser)
    parser.free
    parser = nil
  end

  def parse_auth_header(req,key,error=true)
    val = req["#{cfg.static[:auth_headers_prefix]}#{key}"]
    val = nil if val.is_a?(String) and val.empty?
    if error and !val
      error_unauthorized!("Authentication failed: no #{key.downcase} specified"\
        " in the #{cfg.static[:auth_headers_prefix]}#{key} HTTP header")
    end
    val
  end

  def authenticate!(request)
    user = parse_auth_header(request,'User',false)

    # Authentication with ACL
    if cfg.static[:auth][:acl] and user
      ok,msg = cfg.static[:auth][:acl].auth!(HTTPd.get_sockaddr(request))
      return user if ok
    end

    # Authentication by HTTP Basic Authentication (RFC 2617)
    if request['Authorization'] and cfg.static[:auth][:http_basic]
      ok,msg = cfg.static[:auth][:http_basic].auth!(
        HTTPd.get_sockaddr(request), :req=>request)
      error_unauthorized!("Authentication failed: #{msg}") unless ok
      user = request.user
    elsif user and !user.empty?
      user = parse_auth_header(request,'User')
      cert = parse_auth_header(request,'Certificate',false)

      # Authentication with certificate
      if cfg.static[:auth][:cert] and cert
        ok,msg = cfg.static[:auth][:cert].auth!(
          HTTPd.get_sockaddr(request), :user=>user, :cert=>Base64.strict_decode64(cert))
        error_unauthorized!("Authentication failed: #{msg}") unless ok
      # Authentication with Ident
      elsif cfg.static[:auth][:ident]
        ok,msg = cfg.static[:auth][:ident].auth!(
          HTTPd.get_sockaddr(request), :user=>user, :port=>@httpd.port)
        error_unauthorized!("Authentication failed: #{msg}") unless ok
      else
        error_unauthorized!("Authentication failed: valid methods are "\
          "#{cfg.static[:auth].keys.collect{|k| k.to_s}.join(', ')}")
      end
    else
      # Authentication with Ident
      if cfg.static[:auth][:ident]
        user,_ = cfg.static[:auth][:ident].auth!(
          HTTPd.get_sockaddr(request), :port=>@httpd.port)
        return user if user and user.is_a?(String) and !user.empty?
      # Authentication with certificate
      elsif cfg.static[:auth][:cert] and cert
        user,_ = cfg.static[:auth][:cert].auth!(
          HTTPd.get_sockaddr(request), :cert=>Base64.strict_decode64(cert))
        return user if user and user.is_a?(String) and !user.empty?
      end
      error = "Authentication failed: no user specified "\
        "in the #{cfg.static[:auth_headers_prefix]}User HTTP header"
      error << " or using the HTTP Basic Authentication method" if cfg.static[:auth][:http_basic]
      error_unauthorized!(error)
    end

    user
  end

  def config_httpd_bindings(httpd)
    # GET
    @httpd = httpd
    @httpd.bind([:GET],'/version',:content,cfg.common.version)
    @httpd.bind([:GET],'/auth_headers_prefix',:content,cfg.static[:auth_headers_prefix])
    @httpd.bind([:GET],'/info',:method,:object=>self,:method=>:get_users_info)
    @httpd.bind([:GET],'/clusters',:method,:object=>self,:method=>:get_clusters)
    #@httpd.bind([:GET],'/nodes',:method,:object=>self,:method=>:get_nodes)

    [:deploy,:reboot,:power].each do |kind|
      @httpd.bind([:POST,:PUT,:GET],
        API.path(kind),:filter,:object=>self,:method=>:launch,
        :args=>[1],:static=>[[kind,:work]]
      )
    end

    @httpd.bind([:POST,:GET],API.path(:console),:filter,
      :object=>self,:method=>:launch,
      :args=>[1],:static=>[:console],:name=>[(2..-1)]
    )

    args = {
      :envs => [(1..3)],
      :rights => [(1..3)],
      :nodes => [1],
      :stats => [(1..1)],
    }
    names = {
      :envs => [(4..-1)],
      :rights => [(4..-1)],
      :nodes => [(2..-1)],
      :stats => [(2..-1)],
    }

    [:envs,:rights].each do |kind|
      @httpd.bind([:POST,:GET,:PUT,:DELETE],
        API.path(kind),:filter,:object=>self,
        :method =>:launch,:args=>args[kind],:static=>[kind],:name=>names[kind]
      )
    end

    [:nodes,:stats].each do |kind|
      @httpd.bind([:GET],API.path(kind),:filter,
        :object=>self,:method=>:launch,
        :args=>args[kind],:static=>[kind],:name=>names[kind]
      )
    end
  end

  def prepare(request,kind,query,*args)
    options
  end

  # Returns the method name and args list depending on the param kind
  # for sample: kind = [:deploy,:work], meth = :my_method, args = [1,2,3]
  # if the method :deploy_my_method exists, returns [ :deploy_my_method, [1,2,3] ]
  # else if the method :work_my_method exists, returns [ :work_my_method, [:deploy,1,2,3] ]
  # else throws a NoMethodError exception
  def get_method(kind,meth,args=[])
    if kind.is_a?(Array)
      name = nil
      before = []
      kind.each do |k|
        if respond_to?(:"#{k}_#{meth}")
          name = k
          break
        end
        before << k
      end
      raise NoMethodError.new("undefined method [#{kind.join(',')}]_#{meth} for #{self}","_#{meth}") unless name
      before += args
      [:"#{name}_#{meth}",before]
    else
      if respond_to?(:"#{kind}_#{meth}")
        [:"#{kind}_#{meth}",args]
      else
        raise NoMethodError.new("undefined method #{kind}_#{meth} for #{self}","_#{meth}")
      end
    end
  end

  # Run the specified method, kind defaults to 'work' if no method is found
  def run_wmethod(kind,meth,*args)
    raise unless kind.is_a?(Symbol)
    run_method([kind,:work],meth,*args)
  end

  # Run the specified method depending on kind (kind_meth)
  def run_method(kind,meth,*args)
    name = nil
    begin
      name,args = get_method(kind,meth,args)
      send(name,*args)
    rescue ArgumentError => e
      # if the problem is that the method is called with the wrong nb of args
      if name and e.backtrace[0].split(/\s+/)[-1] =~ /#{get_method(kind,meth)[0]}/ \
      and e.message =~ /wrong number of arguments/
        error_not_found!
      else
        raise e
      end
    rescue NoMethodError => e
      # if the problem is that the method does not exists
      if (name and e.name and e.name.to_sym == get_method(kind,meth)[0]) or (e.name and e.name.to_sym == :"_#{meth}")
        error_not_found!
      else
        raise e
      end
    end
  end

  def launch(params,kind,*args)
    query = nil
    case params[:kind]
    when :POST
      query = :create
    when :GET
      query = :get
    when :PUT
      query = :modify
    when :DELETE
      query = :delete
    else
      raise
    end

    if @shutdown
      error_unavailable!("The service is being shutdown, please try again later")
    end

    # Authenticate the user
    user = authenticate!(params[:request])

    options = init_exec_context(user)
    parse_params_default(params[:params],options)

    begin
      # Prepare the treatment (parse arguments, ...)
      options = run_method(kind,:prepare,params[:params],query,options)

      # Check rights
      # (only check rights if the method 'kind'_rights? is defined)
      check_rights = nil
      begin
        get_method(kind,:'rights?')
        check_rights = true
      rescue
        check_rights = false
      end
      if check_rights
        ok,msg = run_method(kind,:'rights?',options,query,params[:names],*args)
        msg = "You do not the rights to perform this operation" if msg.nil? or msg.empty?
        error_forbidden!(msg) unless ok
      end

      # Run the treatment
      meth = query.to_s
      meth << "_#{params[:names].join('_')}" if params[:names]

      run_method(kind,meth,options,*args) unless options.dry_run
    ensure
      # Clean everything
      if options
        begin
          get_method(kind,:free_exec_context)
          run_method(kind,:free_exec_context,options)
        rescue
          free_exec_context(options)
          wipe_exec_context(options)
        end
        options = nil
      end
    end
  end

  def workflow_create(kind,wid,info,workkind=nil)
    raise unless @workflows_locks[kind]
    raise unless @workflows_info[kind]
    raise unless @httpd

    @workflows_locks[kind].synchronize do
      raise if @workflows_info[kind][wid]
      info[:lock] = Mutex.new
      info[:lock].lock
      @workflows_info[kind][wid] = info
      begin
        yield if block_given?
      ensure
        info[:lock].unlock
      end

      static = nil
      if workkind
        static = workkind
      else
        static = [kind,:work]
      end

      bind(kind,info,'resource') do |httpd,path|
        httpd.bind([:GET,:DELETE],path,:filter,:object=>self,:method =>:launch,
          :args=>[1,3,5,7],:static=>[static],:name=>[2,4,6]
        )
      end
    end
  end

  def workflow_lock(kind,wid)
    @workflows_locks[kind].synchronize do
      kaerror(APIError::INVALID_WORKFLOW_ID) unless @workflows_info[kind][wid]
      @workflows_info[kind][wid][:lock]
    end
  end

  def workflow_list(kind)
    # Take the global lock to iterate on the list but ensure an accurate view
    @workflows_locks[kind].synchronize do
      @workflows_info[kind].each_value do |info|
        info[:lock].synchronize do
          yield(info)
          nil
        end
      end
    end
  end

  def workflow_get(kind,wid)
    raise unless @workflows_locks[kind]
    raise unless @workflows_info[kind]

    ret = nil
    @workflows_locks[kind].synchronize do
      kaerror(APIError::INVALID_WORKFLOW_ID) unless @workflows_info[kind][wid]
      @workflows_info[kind][wid][:lock].lock
    end

    begin
      ret = yield(@workflows_info[kind][wid])
    ensure
      @workflows_info[kind][wid][:lock].unlock
    end

    ret
  end

  def workflow_delete(kind,wid)
    raise unless @workflows_locks[kind]
    raise unless @workflows_info[kind]
    raise unless @httpd

    info = nil
    ret = {}
    @workflows_locks[kind].synchronize do
      kaerror(APIError::INVALID_WORKFLOW_ID) unless @workflows_info[kind][wid]
      info = @workflows_info[kind][wid]
      info[:lock].lock
      unbind(info)
      @workflows_info[kind].delete(wid)
    end

    begin
      ret = yield(info) if block_given?
    ensure
      info[:lock].unlock
    end
    info.clear

    ret
  end

  # Kill workflows involving nodes
  def workflows_kill(nodes,user=nil)
    nodes.each do |node|
      [:deploy,:reboot,:power,:console].each do |kind|
        if @workflows_locks[kind] and @workflows_info[kind]
          to_kill = []
          @workflows_locks[kind].synchronize do
            @workflows_info[kind].each_pair do |wid,info|
              if info[:nodelist].include?(node) and (!user or info[:user] == user)
                to_kill << info
                info[:lock].lock
                @workflows_info[kind].delete(wid)
                unbind(info)
              end
            end
          end
          to_kill.each do |info|
            begin
              if kind == :console
                console_delete!(nil,info)
              else
                run_wmethod(kind,:delete!,nil,info)
              end
            ensure
              info[:lock].unlock
            end
            info.clear
          end
          to_kill.clear
          to_kill = nil
        end
      end
    end
  end

  def workflows_clean()
    clean_threshold = cfg().common.autoclean_threshold
    [:deploy,:reboot,:power].each do |kind|
      to_clean = []
      @workflows_locks[kind].synchronize do
        @workflows_info[kind].each_pair do |wid,info|
          info[:lock].lock
          if info[:done] or info[:error] # Done or Error workflow
            if (Time.now - info[:start_time]) > clean_threshold
              to_clean << info
              @workflows_info[kind].delete(wid)
              unbind(info)
            else
              info[:lock].unlock
            end
          else
            info[:lock].unlock
          end
        end
      end
      to_clean.each do |info|
        begin
          run_wmethod(kind,:delete!,nil,info)
        ensure
          info[:lock].unlock
        end
        info.clear
      end
      to_clean.clear
      to_clean = nil
    end
    nil
  end

  def get_nodes(*args)
    Nodes::sort_list(cfg.common.nodes.make_array_of_hostname)
  end

  def get_clusters(*args)
    cfg.clusters.keys.dup
  end

  def get_users_info(*args)
    ret = {}

    ret[:pxe] = cfg.common.pxe[:dhcp].class.name.split('::').last
    ret[:automata] = {}
    ret[:supported_fs] = {}
    cfg.clusters.each_pair do |cluster,conf|
      ret[:automata][cluster] = {}
      conf.workflow_steps.each do |steps|
        ret[:automata][cluster][steps.name] = []
        steps.to_a.each do |step|
          ret[:automata][cluster][steps.name] << {
            'name' => step[0],
            'retries' => step[1],
            'timeout' => step[2],
          }
        end
      end
      ret[:supported_fs][cluster] = conf.deploy_supported_fs
    end
    ret[:vars] = Microstep.load_deploy_context().keys.sort

    return ret
  end
end

end
