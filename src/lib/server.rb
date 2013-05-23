require 'thread'
require 'securerandom'

require 'httpd'
require 'kadeploy'
require 'kareboot'
require 'kapower'
require 'kaenv'
require 'kastat'
require 'karights'
require 'kanodes'
require 'window'

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
    rescue Exception
      error("Error when parsing configuration files !")
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
      kaerror(KadeployError::DB_ERROR,'Cannot connect to the database')
    end
    db
  end

  def check_database()
    begin
      database_handler().disconnect
    rescue
      error("Cannot connect to the database server #{@config.common.deploy_db_host}")
    end
  end

  def self.error(msg='',abrt = true)
    $stderr.puts msg if msg and !msg.empty?
    exit 1 if abrt
  end

  def error(msg='',abrt = true)
    self.class.error(msg,abrt)
  end

  def kaerror(errno,msg='')
    raise KadeployError.new(errno,nil,msg)
  end

  def error_not_found!()
    raise HTTPd::NotFoundError.new
  end

  def error_unauthorized!()
    raise HTTPd::UnauthorizedError.new
  end

  def error_forbidden!()
    raise HTTPd::ForbiddenError.new
  end

  def error_invalid!()
    raise HTTPd::InvalidError.new
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
    params = HTTPd.parse_body(yield,:json)
    kaerror(APIError::INVALID_CONTENT,'Invalid JSON content') unless params
    options = send(:"#{kind}_prepare",params,:create)
    # authenticate!
    error_unauthorized! unless send(:"#{kind}_rights?",options,:create)
    send(:"#{kind}_create",options)
  end

  def modify_element(kind,*args)
    params = HTTPd.parse_body(yield,:json)
    kaerror(APIError::INVALID_CONTENT,'Invalid JSON content') unless params
    options = send(:"#{kind}_prepare",params,:modify)
    # authenticate!
    error_unauthorized! unless send(:"#{kind}_rights?",options,:modify,args)
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
    params = HTTPd.parse_params(yield)
    options = send(:"#{kind}_prepare",params,:get)
    # authenticate!
    error_unauthorized! unless send(:"#{kind}_rights?",options,:get,args)
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
    params = HTTPd.parse_params(yield)
    options = send(:"#{kind}_prepare",params,:delete)
    # authenticate!
    error_unauthorized! unless send(:"#{kind}_rights?",options,:delete,args)
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
    params = HTTPd.parse_body(yield,:json)
    kaerror(APIError::INVALID_CONTENT,'Invalid JSON content') unless params
    options = send(:"#{kind}_prepare",params)
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
