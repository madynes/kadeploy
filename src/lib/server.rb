require 'thread'
require 'securerandom'
require 'ostruct'

require 'httpd'
require 'api'
require 'authentication'
require 'paramsparser'
require 'kadeploy'
require 'kareboot'
require 'kapower'
require 'kaenv'
require 'kastat'
require 'karights'
require 'kanodes'
require 'window'
require 'rights'

AUTOCLEAN_THRESHOLD = 3600


class KadeployServer
  include Kadeploy
  include Kareboot
  include Kapower
  include Kaenv
  include Kastat
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
      :reboot => Managers::WindowManager.new(
        @config.common.reboot_window,
        @config.common.reboot_window_sleep_time
      ),
      :check => Managers::WindowManager.new(
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
      ret = ConfigInformation::Config.new(false)
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
        info[:resources][resource] = API.ppath(kind,@httpd.url,instpath)
        if block_given?
          yield(@httpd,path)
          info[:bindings] << path
        end
      else
        info[:resources][resource] = {}
        multi.each do |res|
          minstpath = File.join(instpath,res)
          path = API.path(kind,minstpath)
          info[:resources][resource][res] = API.ppath(kind,@httpd.url,minstpath)
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
    ret
  end

  def parse_request_params(request,body_type=:json)
    ret = nil
    begin
      ret = HTTPd.parse_params(request,body_type)
    rescue ArgumentError => ae
      kaerror(APIError::INVALID_CONTENT,ae.message)
    end
    ret
  end

  def parse_params_default(params,context)
    parse_params(params) do |p|
      # Check user/key
      context.user = p.parse('user',String,:mandatory=>:unauthorized).strip
      context.secret_key = p.parse('secret_key',String)
      context.cert = p.parse('cert',Array,:type=>:x509)
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
      @httpd.bind(
        {
          :POST=>'application/json',
          :GET=>nil,
        },
        API.path(kind),:filter,:object=>self,:method=>:launch,
        :args=>[1],:static=>[kind]
      )
    end

    args = {
      :envs => [(1..3)],
      :rights => [(1..3)],
      :nodes => [1],
      :stats => [(1..1)], # !!!
    }
    names = {
      :envs => [(4..-1)],
      :rights => [(4..-1)],
      :nodes => [(2..-1)],
      :stats => [(2..-1)], # !!!
    }

    [:envs,:rights].each do |kind|
      @httpd.bind(
        {
          :POST=>'application/json',
          :PUT=>'application/json',
          :GET=>nil,
          :DELETE=>nil,
        },
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

  def run_method(meth,*args)
    begin
      send(meth.to_sym,*args)
    rescue ArgumentError => e
      # if the problem is that the method is called with the wrong nb of args
      if e.backtrace[0].split(/\s+/)[-1] =~ /#{meth.to_s}/ \
      and e.message =~ /wrong number of arguments/
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
    options = send(:"#{kind}_prepare",
      parse_request_params(params[:request]),query)
    authenticate!(params[:request],options)
    ok,msg = send(:"#{kind}_rights?",options,query,*args)
    error_unauthorized!(msg) unless ok

    if query == :create
      options.info = send(:"#{kind}_init_info",options) if respond_to?(:"#{kind}_init_info")
      send(:"#{kind}_init_resources",options) if respond_to?(:"#{kind}_init_resources")
    end

    #if block_given?
    #  tmp = yield(options)
    #  args = tmp + args if tmp and tmp.is_a?(Array)
    #end

    meth = "#{kind}_#{query}"
    meth << "_#{params[:names].join('_')}" if params[:names]

    run_method(meth.to_sym,options,*args)
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
            :args=>[1,3,5,7],:static=>[kind],:name=>[2,4,6]
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
              deploy_kill(info)
              deploy_free(info)
              if (Time.now - info[:start_time]) > AUTOCLEAN_THRESHOLD
                to_clean << wid
              end
            end
          end
        end

        to_clean.each do |wid|
          send(:"#{kind}_delete",nil,wid)
        end
        to_clean.clear
        to_clean = nil
      end
    end
  end

  def get_nodes()
    @config.common.nodes_desc.make_array_of_hostname
  end

  def get_clusters()
    @config.cluster_specific.keys
  end

  def get_users_info
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
