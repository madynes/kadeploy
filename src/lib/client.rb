# Kadeploy 3.1
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2011
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

STATUS_UPDATE_DELAY = 2
R_HOSTNAME = /\A[A-Za-z0-9\.\-\[\]\,]*\Z/

require 'configparser'

require 'thread'
require 'net/http'
require 'net/https'
require 'timeout'
require 'json'

HTTP_SECURE = true

class Client
  def initialize(server,port,nodes)
    @server = server
    @port = port
    @api_id = nil
    @nodes = nodes
  end

  def kill
    HTTP::delete api_path()
  end

  def api_path(path = '',api_dir=API_DIR)
    tmp = File.join("http#{'s' if HTTP_SECURE}://#{@server}:#{@port}",api_dir)
    if @api_id
      File.join(tmp,@api_id,path)
    else
      File.join(tmp,path)
    end
  end

  def self.api_path(server,port,path='',api_dir=API_DIR)
    File.join("http#{'s' if HTTP_SECURE}://#{server}:#{port}",api_dir,path)
  end

  def self.error(msg='',abrt = true)
    $stderr.puts msg if msg and !msg.empty?
    exit 1 if abrt
  end

  def self.kill()
    $threads.each do |thread|
      thread.kill
      thread.join
    end

    $clients.each do |client|
      client.kill
    end
  end

  def self.load_configfile()
    configfile = File.join($kadeploy_config_directory,'client_conf.yml')
    begin
      begin
        config = YAML.load_file(configfile)
      rescue ArgumentError
        raise ArgumentError.new("Invalid YAML file '#{configfile}'")
      rescue Errno::ENOENT
        raise ArgumentError.new("File not found '#{configfile}'")
      end

      servers = {}
      cp = ConfigParser.new(config)

      cp.parse('servers',true,Array) do
        servers[cp.value('name',String)] = [
          cp.value('hostname',String),
          cp.value('port',Fixnum)
        ]
      end
      servers['default'] = cp.value('default',String,nil,servers.keys)
    rescue ArgumentError => ae
      puts "Error(#{configfile}) #{ae.message}"
      raise "Problem in configuration"
    end

    if servers.empty?
      puts "No server specified"
      raise "Problem in configuration"
    end

    return servers
  end

  def self.load_machine(nodelist, hostname)
    hostname.strip!
    if R_HOSTNAME =~ hostname
      nodelist.push(hostname) unless hostname.empty?
    else
      error("Invalid hostname: #{hostname}")
    end
  end

  def self.load_machinefile(nodelist, param)
    if (param == "-") then
      STDIN.read.split("\n").sort.uniq.each do |hostname|
        load_machine(nodelist,hostname)
      end
    else
      if File.readable?(param) then
        IO.readlines(param).sort.uniq.each do |hostname|
          load_machine(nodelist,hostname)
        end
      else
        error("The file #{param} cannot be read")
      end
    end
  end

    return true
  end

  def self.launch()
    options = parse_options()
    error() unless options

    if options.get_version
      info = options.servers[options.chosen_server]
      version = JSON::parse(HTTP::get(api_path(info[0],info[1],'/version','')))
      puts "(#{info[0]}) Kadeploy version: #{version}"
      exit 0
    elsif options.get_users_info
      info = options.servers[options.chosen_server]
      res = JSON::parse(HTTP::get(api_path(info[0],info[1],'/info','')))
      puts "(#{server}) Kadeploy server configuration:"
      puts "(#{server})   Custom PXE boot method: #{res[:pxe]}"
      puts "(#{server})   Deployment environment:"
      puts "(#{server})     Supported file systems:"
      res[:supported_fs].each_pair do |clname,fslist|
        puts "(#{server})       #{clname}: #{fslist.join(',')}"
      end
      puts "(#{server})     Variables exported to custom scripts:"
      res[:vars].each do |var|
        puts "(#{server})       #{var}"
      end
      exit 0
    end

    # Check if servers are reachable
    if options.multi_server
      options.servers.each_pair do |server,info|
        next if server.downcase == "default"
        error("The #{server} server is unreachable",false) \
          unless PortScanner::is_open?(info[0], info[1])
      end
    else
      info = options.servers[options.chosen_server]
      error("Unknown server #{info[0]}") unless info
      error("The #{info[0]} server is unreachable") \
        unless PortScanner::is_open?(info[0], info[1])
    end

    $clients = []
    treated = []
    # Dispatch the nodes from the list by server (multiserver)
    if options.multi_server
      options.servers.each_pair do |server,info|
        next if server.downcase == "default"
        nodelist = nil
        begin
          Timeout.timeout(8) do
            nodelist = JSON::parse(HTTP::get(api_path(info[0],info[1],'/nodes')))
          end
        rescue Timeout::Error
          error("Cannot check the nodes on the #{info[0]} server")
        end
        nodes = options.node_array & nodelist
        treated += nodes
        $clients << self.new(info[0],info[1],nodes)
      end
    else
      info = options.servers[options.chosen_server]
      treated += options.node_array
      $clients << self.new(info[0],info[1],options.node_array)
    end

    # Check that every nodes was treated
    error("The nodes #{(options.node_array - treated).join(", ")} does not belongs to any server") unless treated.sort == options.node_array.sort

    # Launch the deployment
    $threads = []
    $clients.each do |client|
      $threads << Thread.new do
        Thread.current[:client] = client
        client.run(options)
      end
    end
  end

  def self.parse_options()
    raise
  end

  def run(options)
    raise
  end
end

