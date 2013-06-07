
require 'window'

class KadeployServer
  attr_reader :host,:port

  def initialize()
    @config = load_config()
    @host = @config.common.kadeploy_server
    @port = @config.common.kadeploy_server_port
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
  end

  def load_config()
    ret = nil
    begin
      ret = ConfigInformation::Config.new(false)
    rescue
      error("Bad configuration: #{$!}")
    end
    ret
  end

  def check_database()
    db = Database::DbFactory.create(@config.common.db_kind)
    if db.connect(
      @config.common.deploy_db_host,
      @config.common.deploy_db_login,
      @config.common.deploy_db_passwd,
      @config.common.deploy_db_name
    ) then
      db.disconnect
    else
      error("Cannot connect to the database server #{@config.common.deploy_db_host}")
    end
  end

  def kill
  end

  def self.error(msg='',abrt = true)
    $stderr.puts msg if msg and !msg.empty?
    exit 1 if abrt
  end

  def error(msg='',abrt = true)
    self.class.error(msg,abrt)
  end


  def get_version()
    @config.common.version
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
