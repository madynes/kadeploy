require 'thread'
require 'securerandom'
require 'ostruct'

require 'httpd'
require 'api'
require 'authentication'
require 'paramsparser'
require 'kaworkflow'
require 'kadeploy'
require 'kareboot'
require 'kapower'
require 'kaenvs'
require 'kastats'
require 'karights'
require 'kanodes'
require 'window'
require 'rights'
require 'http'

module Kadeploy
AUTOCLEAN_THRESHOLD = 21600 # 6h

class KadeployServer
  include Kaworkflow
  include Kadeploy
  include Kareboot
  include Kapower
  include Kaenvs
  include Kastats
  include Karights
  include Kanodes

  attr_reader :host, :port, :secure, :cert, :private_key, :logfile, :config, :window_managers, :httpd

  def initialize()
    @config = load_config()
    @host = @config.common.kadeploy_server
    @port = @config.common.kadeploy_server_port
    @secure = @config.common.secure_server
    @private_key = @config.common.private_key
    @cert = @config.common.cert
    @logfile = @config.common.log_to_file
    check_database()
    @window_managers = {
      :reboot => WindowManager.new(
        @config.common.reboot_window,
        @config.common.reboot_window_sleep_time
      ),
      :check => WindowManager.new(
        @config.common.nodes_check_window,
        1
      ),
    }
    @workflows_locks = {
      :deploy => Mutex.new,
      :reboot => Mutex.new,
      :power => Mutex.new,
    }
    @workflows_info = {
      :deploy => {},
      :reboot => {},
      :power => {},
    }
    @httpd = nil
  end

  def kill
  end

  def load_config()
    ret = nil
    begin
      ret = Configuration::Config.new(false)
    rescue KadeployError, ArgumentError => e
      kaerror(APIError::BAD_CONFIGURATION,e.message)
    end
    ret
  end

  def database_handler()
    db = Database::DbFactory.create(@config.common.db_kind)
    unless db.connect(
      @config.common.deploy_db_host,
      @config.common.deploy_db_login,
      @config.common.deploy_db_passwd,
      @config.common.deploy_db_name
    ) then
      kaerror(APIError::DATABASE_ERROR,'Cannot connect to the database')
    end
    db
  end

  def rights_handler(db)
    Rights::Factory.create(config.common.rights_kind,db)
  end

  def check_database()
    begin
      database_handler().disconnect
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
    raise HTTPd::UnauthorizedError.new(msg)
  end

  def error_forbidden!(msg=nil)
    raise HTTPd::ForbiddenError.new(msg)
  end

  def error_invalid!(msg=nil)
    raise HTTPd::InvalidError.new(msg)
  end

  def uuid(prefix='')
    "#{prefix}#{SecureRandom.uuid}"
  end

  def bind(kind,info,resource,path=nil,multi=nil)
    if @httpd
      instpath = File.join(info[:wid],path||'')
      unless multi
        path = API.path(kind,instpath)
        info[:resources][resource] = HTTP::Client.path_params(
          API.ppath(kind,@httpd.url,instpath),{:user=>info[:user]})
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
            API.ppath(kind,@httpd.url,minstpath),{:user=>info[:user]})
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

  def init_exec_context()
    ret = OpenStruct.new
    ret.user = nil
    ret.secret_key = nil
    ret.cert = nil
    ret.info = nil
    ret.dry_run = nil
    ret
  end

  def parse_params_default(params,context)
    parse_params(params) do |p|
      # Check user/key
      context.user = p.parse('user',String,:mandatory=>:unauthorized).strip
      context.secret_key = p.parse('secret_key',String)
      context.cert = p.parse('cert',Array,:type=>:x509)
      context.dry_run = p.parse('dry_run',nil,:toggle=>true)
    end
  end

  def parse_params(params)
    parser = ParamsParser.new(params,@config)
    yield(parser)
    parser = nil
  end

  def authenticate!(request,options)
    # Authentication with certificate
    if config.common.auth[:cert] and options.cert
      ok,msg = config.common.auth[:cert].auth!(
        HTTPd.get_sockaddr(request), :cert => options.cert)
      error_unauthorized!("Authentication failed: #{msg}") unless ok
      # TODO: necessary ?
      #unless config.common.almighty_env_users.include?(options.user)
      #  error_unauthorized!("Authentication failed: "\
      #    "only almighty user can be authenticated with the secret key")
      #end
    # Authentication by secret key
    elsif config.common.auth[:secret_key] and options.secret_key
      ok,msg = config.common.auth[:secret_key].auth!(
        HTTPd.get_sockaddr(request), :key => options.secret_key)
      error_unauthorized!("Authentication failed: #{msg}") unless ok
      # TODO: necessary ?
      #unless config.common.almighty_env_users.include?(options.user)
      #  error_unauthorized!("Authentication failed: "\
      #    "only almighty user can be authenticated with the secret key")
      #end
    # Authentication with Ident
    elsif config.common.auth[:ident]
      ok,msg = config.common.auth[:ident].auth!(
        HTTPd.get_sockaddr(request), :user => options.user, :port => @httpd.port)
      error_unauthorized!("Authentication failed: #{msg}") unless ok
    else
      error_unauthorized!("Authentication failed: valid methods are "\
        "#{config.common.auth.keys.collect{|k| k.to_s}.join(', ')}")
    end
  end

  def config_httpd_bindings(httpd)
    # GET
    @httpd = httpd
    @httpd.bind([:GET],'/version',:content,{:version => @config.common.version})
    @httpd.bind([:GET],'/info',:method,:object=>self,:method=>:get_users_info)
    @httpd.bind([:GET],'/clusters',:method,:object=>self,:method=>:get_clusters)
    #@httpd.bind([:GET],'/nodes',:method,:object=>self,:method=>:get_nodes)

    [:deploy,:reboot,:power].each do |kind|
      @httpd.bind([:POST,:PUT,:GET],
        API.path(kind),:filter,:object=>self,:method=>:launch,
        :args=>[1],:static=>[[kind,:work]]
      )
    end

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
      raise NoMethodError.new("undefined method [#{kind.join(',')}]_#{meth} for #{self.inspect}:#{self.class.name}","_#{meth}") unless name
      before += args
      [:"#{name}_#{meth}",before]
    else
      if respond_to?(:"#{kind}_#{meth}")
        [:"#{kind}_#{meth}",args]
      else
        raise NoMethodError.new("undefined method #{kind}_#{meth} for #{self.inspect}:#{self.class.name}","#{kind}_#{meth}")
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
      if (name and e.name.to_sym == get_method(kind,meth)[0]) or (e.name.to_sym == :"_#{meth}")
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

    # prepare the treatment
    options = run_method(kind,:prepare,params[:params],query)
    authenticate!(params[:request],options)
    ok,msg = run_method(kind,:'rights?',options,query,params[:names],*args)
    error_unauthorized!(msg) unless ok

    meth = query.to_s
    meth << "_#{params[:names].join('_')}" if params[:names]
    run_method(kind,meth,options,*args) unless options.dry_run
  end

  def workflow_create(kind,wid,info)
    raise unless @workflows_locks[kind]
    raise unless @workflows_info[kind]
    raise unless @httpd

    error = nil
    @workflows_locks[kind].synchronize do
      if @workflows_info[kind][wid]
        error = true
      else
        yield if block_given?
        @workflows_info[kind][wid] = info
        bind(kind,info,'resource') do |httpd,path|
          httpd.bind([:GET,:DELETE],path,:filter,:object=>self,:method =>:launch,
            :args=>[1,3,5,7],:static=>[[kind,:work]],:name=>[2,4,6]
          )
        end
      end
    end
    if error
      raise if error == true
      kaerror(error)
    end
  end

  def workflow_get(kind,wid=nil)
    raise unless @workflows_locks[kind]
    raise unless @workflows_info[kind]

    error = nil
    ret = nil
    @workflows_locks[kind].synchronize do
      if wid
        if @workflows_info[kind][wid]
          ret = yield(@workflows_info[kind][wid])
        else
          error = APIError::INVALID_WORKFLOW_ID
        end
      else
        ret = yield(@workflows_info[kind].values)
      end
    end
    kaerror(error) if error
    ret
  end

  def workflow_delete(kind,wid)
    raise unless @workflows_locks[kind]
    raise unless @workflows_info[kind]
    raise unless @httpd

    error = nil
    ret = {}
    @workflows_locks[kind].synchronize do
      if @workflows_info[kind][wid]
        ret = yield(@workflows_info[kind][wid]) if block_given?
        unbind(@workflows_info[kind][wid])
      else
        error = APIError::INVALID_WORKFLOW_ID
      end
      @workflows_info[kind].delete(wid)
    end
    kaerror(error) if error
    ret
  end

  def workflows_clean()
    [:deploy,:reboot,:power].each do |kind|
      if @workflows_locks[kind] and @workflows_info[kind]
        to_clean = []
        @workflows_locks[kind].synchronize do
          @workflows_info[kind].each_pair do |wid,info|
            if info[:done] # Done workflow
              if (Time.now - info[:start_time]) > AUTOCLEAN_THRESHOLD
                to_clean << wid
              end
            elsif !info[:thread].alive? # Dead workflow
              run_wmethod(kind,:kill,info)
              run_wmethod(kind,:free,info)
              if (Time.now - info[:start_time]) > AUTOCLEAN_THRESHOLD
                to_clean << wid
              end
            end
          end
        end

        to_clean.each do |wid|
          run_wmethod(kind,:delete,nil,wid)
        end
        to_clean.clear
        to_clean = nil
      end
    end
  end

  def get_nodes(*args)
    @config.common.nodes_desc.make_array_of_hostname
  end

  def get_clusters(*args)
    @config.cluster_specific.keys
  end

  def get_users_info(*args)
    ret = {}

    ret[:pxe] = @config.common.pxe[:dhcp].class.name.split('::').last
    ret[:supported_fs] = {}
    @config.cluster_specific.each_pair do |cluster,conf|
      ret[:supported_fs][cluster] = conf.deploy_supported_fs
    end
    ret[:vars] = Microstep.load_deploy_context().keys.sort

    return ret
  end
end

end
