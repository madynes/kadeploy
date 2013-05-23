require 'thread'
require 'securerandom'
require 'ostruct'

require 'httpd'
require 'authentication'
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

  attr_reader :host, :port, :logfile, :config, :window_managers, :httpd

  def initialize()
    @config = load_config()
    @host = @config.common.kadeploy_server
    @port = @config.common.kadeploy_server_port
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
        path = send(:"#{kind}_path",instpath)
        info[:resources][resource] = send(:"#{kind}_path",instpath,@httpd.url)
        if block_given?
          yield(@httpd,path)
          info[:bindings] << path
        end
      else
        info[:resources][resource] = {}
        multi.each do |res|
          minstpath = File.join(instpath,res)
          path = send(:"#{kind}_path",minstpath)
          info[:resources][resource][res] = send(:"#{kind}_path",minstpath,@httpd.url)
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
    ret
  end

  def parse_user(u)
    error_unauthorized!('No user was specified') if !u or u.empty?
    user = u
    user = user[0] if user.is_a?(Array)
    error_invalid!('The \'user\' field must be a String') unless user.is_a?(String)
    user.strip!
    user
  end

  def parse_secret_key(k)
    key = nil
    if k and !k.empty?
      key = k
      key = key[0] if key.is_a?(Array)
      error_invalid!('The \'key\' field must be a String') unless key.is_a?(String)
      key.strip!
    end
    key
  end

  def parse_cert(c)
    cert = nil
    if c and !c.empty?
      cert = c
      cert = cert.join("\n") if cert.is_a?(Array)
      error_invalid!('The \'cert\' field must be a String') unless cert.is_a?(String)
      begin
        cert = OpenSSL::X509::Certificate.new(cert)
      rescue Exception => e
        error_invalid!("Invalid x509 certificate (#{e.message})")
      end
    end
    cert
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

    #['deploy','reboot','power'].each do |kind|
    #  @httpd.bind({:POST=>'application/json'},send(:"#{kind}_path")) do |_,request|
    #    begin
    #      run_workflow(kind,JSON::load(request.body))
    #    rescue JSON::ParserError
    #      kaerror(APIError::INVALID_CONTENT,'Invalid JSON content')
    #    end
    #  end
    #end
    [:deploy,:reboot,:power].each do |kind|
      @httpd.bind({:POST=>'application/json'},send(:"#{kind}_path"),:method,
        :object=>self,:method=>:run_workflow,:args=>[kind])
    end

    args = {
      :envs => [(1..3)],
      :rights => [(1..3)], # !!!
      :nodes => [(1..1)], # !!!
      :stats => [(1..1)], # !!!
    }
    names = {
      :envs => [(4..-1)],
      :rights => [(4..-1)], # !!!
      :nodes => [(2..-1)], # !!!
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
        send(:"#{kind}_path"),:filter,:object=>self,
        :method => HTTPd::ContentBinding[
          :POST => :create_element,
          :PUT => :modify_element,
          :GET => :get_element,
          :DELETE => :delete_element,
        ],:args=>{:static=>[kind],:dynamic=>args[kind]},:name=>names[kind]
      )
    end

    [:nodes,:stats].each do |kind|
      @httpd.bind([:GET],send(:"#{kind}_path"),:filter,
        :object=>self, :method=>:get_element,
        :args=>{:static=>[kind],:dynamic=>args[kind]},:name=>names[kind]
      )
    end
  end

  def create_element(kind)
    request = yield
    params = nil
    begin
      params = HTTPd.parse_body(request,:json)
    rescue JSON::ParserError
      kaerror(APIError::INVALID_CONTENT,'Invalid JSON content')
    end
    kaerror(APIError::INVALID_CONTENT,'Invalid JSON content') unless params
    options = send(:"#{kind}_prepare",params,:create)
    authenticate!(request,options)
    ok,msg = send(:"#{kind}_rights?",options,:create)
    error_unauthorized!(msg) unless ok
    send(:"#{kind}_create",options)
  end

  def modify_element(kind,*args)
    request = yield
    params = nil
    begin
      params = HTTPd.parse_body(request,:json)
    rescue JSON::ParserError
      kaerror(APIError::INVALID_CONTENT,'Invalid JSON content')
    end
    kaerror(APIError::INVALID_CONTENT,'Invalid JSON content') unless params
    options = send(:"#{kind}_prepare",params,:modify)
    authenticate!(request,options)
    ok,msg = send(:"#{kind}_rights?",options,:modify,args)
    error_unauthorized!(msg) unless ok
    begin
      send(:"#{kind}_modify",options,*args)
    rescue ArgumentError => e
      # if the problem is that the method is called with the wrong nb of args
      if e.backtrace[0].split(/\s+/)[-1] =~ /#{kind}_modify/ \
      and e.message =~ /wrong number of arguments/
        error_not_found!
      else
        raise e
      end
    end
  end

  def get_element(kind,*args)
    request = yield
    params = nil
    begin
      params = HTTPd.parse_body(request,:json)
    rescue JSON::ParserError
      kaerror(APIError::INVALID_CONTENT,'Invalid JSON content')
    end
    if params
      params.merge!(HTTPd.parse_params(request))
    else
      params = HTTPd.parse_params(request)
    end
    options = send(:"#{kind}_prepare",params,:get)
    authenticate!(request,options)
    ok,msg = send(:"#{kind}_rights?",options,:get,args)
    error_unauthorized!(msg) unless ok
    begin
      send(:"#{kind}_get",options,*args)
    rescue ArgumentError => e
      # if the problem is that the method is called with the wrong nb of args
      if e.backtrace[0].split(/\s+/)[-1] =~ /#{kind}_get/ \
      and e.message =~ /wrong number of arguments/
        error_not_found!
      else
        raise e
      end
    end
  end

  def delete_element(kind,*args)
    request = yield
    params = nil
    begin
      params = HTTPd.parse_body(request,:json)
    rescue JSON::ParserError
      kaerror(APIError::INVALID_CONTENT,'Invalid JSON content')
    end
    if params
      params.merge!(HTTPd.parse_params(request))
    else
      params = HTTPd.parse_params(request)
    end
    options = send(:"#{kind}_prepare",params,:delete)
    authenticate!(request,options)
    ok,msg = send(:"#{kind}_rights?",options,:delete,args)
    error_unauthorized!(msg) unless ok
    begin
      send(:"#{kind}_delete",options,*args)
    rescue ArgumentError => e
      # if the problem is that the method is called with the wrong nb of args
      if e.backtrace[0].split(/\s+/)[-1] =~ /#{kind}_delete/ \
      and e.message =~ /wrong number of arguments/
        error_not_found!
      else
        raise e
      end
    end
  end

  def run_workflow(kind)
    request = yield
    params = nil
    begin
      params = HTTPd.parse_body(request,:json)
    rescue JSON::ParserError
      kaerror(APIError::INVALID_CONTENT,'Invalid JSON content')
    end
    kaerror(APIError::INVALID_CONTENT,'Invalid JSON content') unless params
    options = send(:"#{kind}_prepare",params)
    authenticate!(request,options)
    wid,resources = send(:"#{kind}_run",options)
    { :wid => wid, :resources => resources }
  end

  def clean_workflows()
    [:deploy,:reboot,:power].each do |kind|
      if @workflows_locks[kind] and @workflows_info[kind]
        to_clean = []
        @workflows_locks[kind].synchronize do
          @workflows_info[kind].each_pair do |wid,info|
            if info[:done] and (Time.now - info[:start_time]) > AUTOCLEAN_THRESHOLD
              to_clean << wid
            end
          end
        end

        to_clean.each do |wid|
          send(:"#{kind}_delete",wid)
        end
        to_clean.clear
        to_clean = nil
      end
    end
  end

  def create_workflow(kind,wid,info)
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
          httpd.bind([:GET,:DELETE],path,:filter,:object=>self,
            :method => HTTPd::ContentBinding[
              :GET => :"#{kind}_get",
              :DELETE => :"#{kind}_delete",
            ],:args=>[1,3,5,7],:name=>[2,4,6]
          )
          #httpd.bind([:DELETE],path,:method,
          #  :object=>self,:method=>:"#{kind}_delete")
        end
        send(:"#{kind}_bindings",info)
      end
    end
    if error
      raise if error == true
      kaerror(error)
    end
  end

  def get_workflow(kind,wid)
    raise unless @workflows_locks[kind]
    raise unless @workflows_info[kind]

    error = nil
    ret = nil
    @workflows_locks[kind].synchronize do
      if @workflows_info[kind][wid]
        ret = yield(@workflows_info[kind][wid])
      else
        error = APIError::INVALID_WORKFLOW_ID
      end
    end
    kaerror(error) if error
    ret
  end

  def delete_workflow(kind,wid)
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

  def get_nodes()
    @config.common.nodes_desc.set.collect{|node| node.hostname}
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
