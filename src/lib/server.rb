require 'thread'
require 'securerandom'

require 'kadeploy'
require 'kareboot'
require 'kapower'
require 'window'

AUTOCLEAN_THRESHOLD = 3600


class KadeployServer
  include Kadeploy
  include Kareboot
  include Kapower

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

  def uuid(prefix='')
    "#{prefix}#{SecureRandom.uuid}"
  end


  def check_http_request(request,content_type='application/json')
    if request['Content-Type'] == content_type
      request.body
    else
      kaerror(HTTPError::INVALID_CONTENT_TYPE)
    end
  end


  def config_http_bindings(httpd)
    # GET
    @httpd = httpd
    @httpd.bind([:GET],'/version',{ :version => @config.common.version })
    @httpd.bind([:GET],'/info',self,:get_users_info)
    @httpd.bind([:GET],'/nodes',self,:get_nodes)

    # POST
    ['deploy','reboot','power'].each do |kind|
      @httpd.bind([:POST],send(:"#{kind}_path")) do |request|
        run_workflow(kind,JSON::load(check_http_request(request)))
      end
    end
  end

  def run_workflow(kind,params)
    options = send(:"#{kind}_prepare",params)
    wid = send(:"#{kind}_run",options)
    { :wid => wid, :url => send(:"#{kind}_path",wid) }
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
          send(:"#{kind.to_s}_delete",wid)
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
        @httpd.bind([:GET,:DELETE],send(:"#{kind}_path",wid)) do |request,method|
          send(:"#{kind.to_s}_#{method.to_s.downcase}",wid)
        end
        send(:"#{kind.to_s}_bindings",@httpd,info)
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
      else
        error = APIError::INVALID_WORKFLOW_ID
      end
      @workflows_info[kind].delete(wid)
      @httpd.unbind(deploy_path(wid))
    end
    kaerror(error) if error
    ret
  end

  def get_nodes()
    @config.common.nodes_desc.set.collect{|node| node.hostname}
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
