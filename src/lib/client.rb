# Kadeploy 3.1
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2011
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

CONTACT_EMAIL = "kadeploy3-users@lists.gforge.inria.fr"
USER = `id -nu`.strip

STATUS_UPDATE_DELAY = 2
R_HOSTNAME = /\A[A-Za-z0-9\.\-\[\]\,]*\Z/

require 'configparser'
require 'port_scanner'

require 'thread'
require 'uri'
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
    connect() do |client|
      client.delete api_path()
    end
  end

  def api_path(path = '',api_dir=API_DIR)
    tmp = File.join("http#{'s' if HTTP_SECURE}://#{@server}:#{@port}",api_dir)
    if @api_id
      URI(File.join(tmp,@api_id,path))
    else
      URI(File.join(tmp,path))
    end
  end

  def self.api_path(server,port,path='',api_dir=API_DIR)
    URI(File.join("http#{'s' if HTTP_SECURE}://#{server}:#{port}",api_dir,path))
  end

  def self.error(msg='',abrt = true)
    $stderr.puts msg if msg and !msg.empty?
    exit 1 if abrt
  end

  def error(msg='',abrt = true)
    self.class.error(msg,abrt)
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
      cp = ConfigInformation::ConfigParser.new(config)

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

  def self.load_envfile(srcfile)
    tmpfile = Tempfile.new("env_file")
    begin
      Managers::Fetch[srcfile,KadeployAsyncError::LOAD_ENV_FROM_FILE_ERROR].grab(tmpfile.path)
      tmpfile.close
    rescue KadeployError => ke
      msg = KadeployError.to_msg(ke.errno) || ''
      msg = "#{msg} (error ##{ke.errno})\n" if msg and !msg.empty?
      msg += ke.message if ke.message and !ke.message.empty?
      error(msg)
      tmpfile.unlink
      return false
    end

    unless `file --mime-type --brief #{tmpfile.path}`.chomp == "text/plain"
      error("The file #{srcfile} should be in plain text format")
      tmpfile.unlink
      return false
    end

    begin
      ret = YAML.load_file(tmpfile.path)
    rescue ArgumentError
      error("Invalid YAML file '#{srcfile}'")
      tmpfile.unlink
      ret = nil
    rescue Errno::ENOENT
      error("File not found '#{srcfile}'")
      tmpfile.unlink
      ret = nil
    end

    tmpfile.unlink
    return ret
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
    return true
  end

  def self.load_custom_ops_file(file)
    if not File.readable?(file) then
      error("The file #{file} cannot be read")
      return false
    end

    begin
      config = YAML.load_file(file)
    rescue ArgumentError
      puts "Invalid YAML file '#{file}'"
      return false
    rescue Errno::ENOENT
      return true
    end

    unless config.is_a?(Hash)
      puts "Invalid file format '#{file}'"
      return false
    end
    #example of line: macro_step,microstep@cmd1%arg%dir,cmd2%arg%dir,...,cmdN%arg%dir
    ret = { :operations => {}, :overrides => {}}
    customops = ret[:operations]
    customover = ret[:overrides]

    config.each_pair do |macro,micros|
      unless micros.is_a?(Hash)
        puts "Invalid file format '#{file}'"
        return false
      end
      unless check_macrostep_instance(macro)
        error("[#{file}] Invalid macrostep '#{macro}'")
        return false
      end
      customops[macro.to_sym] = {} unless customops[macro.to_sym]
      micros.each_pair do |micro,operations|
        unless operations.is_a?(Hash)
          puts "Invalid file format '#{file}'"
          return false
        end
        unless check_microstep(micro)
          error("[#{file}] Invalid microstep '#{micro}'")
          return false
        end
        customops[macro.to_sym][micro.to_sym] = [] unless customops[macro.to_sym][micro.to_sym]
        operations.each_pair do |operation,ops|
          unless ['pre-ops','post-ops','substitute','override'].include?(operation)
            error("[#{file}] Invalid operation '#{operation}'")
            return false
          end

          if operation == 'override'
            customover[macro.to_sym] = {} unless customover[macro.to_sym]
            customover[macro.to_sym][micro.to_sym] = true
            next
          end

          ops.each do |op|
            unless op['name']
              error("[#{file}] Operation #{operation}: 'name' field missing")
              return false
            end
            unless op['action']
              error("[#{file}] Operation #{operation}: 'action' field missing")
              return false
            end
            unless ['exec','send','run'].include?(op['action'])
              error("[#{file}] Invalid action '#{op['action']}'")
              return false
            end

            scattering = op['scattering'] || 'tree'
            timeout = op['timeout'] || 0
            begin
              timeout = Integer(timeout)
            rescue ArgumentError
              error("[#{file}] The field 'timeout' shoud be an integer")
              return false
            end
            retries = op['retries'] || 0
            begin
              retries = Integer(retries)
            rescue ArgumentError
              error("[#{file}] The field 'retries' shoud be an integer")
              return false
            end

            case op['action']
            when 'send'
              unless op['file']
                error("[#{file}] Operation #{operation}: 'file' field missing")
                return false
              end
              unless op['destination']
                error("[#{file}] Operation #{operation}: 'destination' field missing")
                return false
              end
              customops[macro.to_sym][micro.to_sym] << {
                :action => op['action'].to_sym,
                :name => "#{micro}-#{op['name']}",
                :file => op['file'],
                :destination => op['destination'],
                :timeout => timeout,
                :retries => retries,
                :scattering => scattering.to_sym,
                :target => operation.to_sym
              }
            when 'run'
              unless op['file']
                error("[#{file}] Operation #{operation}: 'file' field missing")
                return false
              end
              op['params'] = '' unless op['params']
              customops[macro.to_sym][micro.to_sym] << {
                :action => op['action'].to_sym,
                :name => "#{micro}-#{op['name']}",
                :file => op['file'],
                :params => op['params'],
                :timeout => timeout,
                :retries => retries,
                :scattering => scattering.to_sym,
                :target => operation.to_sym
              }
            when 'exec'
              unless op['command']
                error("[#{file}] Operation #{operation}: 'command' field missing")
                return false
              end
              customops[macro.to_sym][micro.to_sym] << {
                :action => op['action'].to_sym,
                :name => "#{micro}-#{op['name']}",
                :command => op['command'],
                :timeout => timeout,
                :retries => retries,
                :scattering => scattering.to_sym,
                :target => operation.to_sym
              }
            end
          end
        end
      end
    end
    return ret
  end

  def self.check_macrostep_interface(name)
    macrointerfaces = ObjectSpace.each_object(Class).select { |klass|
      klass.superclass == Macrostep
    }
    return macrointerfaces.include?(name)
  end

  def self.check_macrostep_instance(name)
    # Gathering a list of availables macrosteps
    macrosteps = ObjectSpace.each_object(Class).select { |klass|
      klass.ancestors.include?(Macrostep)
    }

    # Do not consider rought step names as valid
    macrointerfaces = ObjectSpace.each_object(Class).select { |klass|
      klass.superclass == Macrostep
    }
    macrointerfaces.each { |interface| macrosteps.delete(interface) }

    macrosteps.collect!{ |klass| klass.name }

    return macrosteps.include?(name)
  end

  def self.check_microstep(name)
    # Gathering a list of availables microsteps
    microsteps = Microstep.instance_methods.select{
      |microname| microname =~ /^ms_/
    }
    microsteps.collect!{ |microname| microname.to_s.sub(/^ms_/,'') }

    return microsteps.include?(name)
  end

  def self.get(server,port,path)
    res = nil
    connect(server,port) do |client|
      res = JSON::load(client.get(path).body)
      yield(res) if block_given?
    end
    res
  end

  def get(path)
    self.class.get(@server,@port,path)
  end

  def self.get_nodelist(server,port)
    nodelist = nil
    begin
      Timeout.timeout(8) do
        nodelist = get(server,port,'/nodes')
      end
    rescue Timeout::Error
      error("Cannot check the nodes on the #{server} server")
    rescue Errno::ECONNRESET
      error("The #{server} server refused the connection on port #{port}")
    end
    nodelist
  end

  def self.launch()
    options = nil
    error() unless options = parse_options()
    error() unless check_options(options)

    if options[:get_version]
      info = options[:servers][options[:chosen_server]]
      get(info[0],info[1],'/version') do |res|
        puts "(#{info[0]}) Kadeploy version: #{res['version']}"
      end
      exit 0
    elsif options[:get_users_info]
      info = options[:servers][options[:chosen_server]]
      get(info[0],info[1],'/info') do |res|
        puts "(#{info[0]}) Kadeploy server configuration:"
        puts "(#{info[0]})   Custom PXE boot method: #{res['pxe']}"
        puts "(#{info[0]})   Deployment environment:"
        puts "(#{info[0]})     Supported file systems:"
        res['supported_fs'].each_pair do |clname,fslist|
          puts "(#{info[0]})       #{clname}: #{fslist.join(',')}"
        end
        puts "(#{info[0]})     Variables exported to custom scripts:"
        res['vars'].each do |var|
          puts "(#{info[0]})       #{var}"
        end
      end
      exit 0
    end

    # Check if servers are reachable
    if options[:multi_server]
      options[:servers].each_pair do |server,inf|
        next if server.downcase == "default"
        error("The #{server} server is unreachable",false) unless PortScanner::is_open?(inf[0], inf[1])
      end
    else
      info = options[:servers][options[:chosen_server]]
      error("Unknown server #{info[0]}") unless info
      error("The #{info[0]} server is unreachable") unless PortScanner::is_open?(info[0], info[1])
    end

    $clients = []
    treated = []
    # Dispatch the nodes from the list by server (multiserver)
    if options[:multi_server]
      options[:servers].each_pair do |server,inf|
        next if server.downcase == 'default'
        nodelist = get_nodelist(inf[0],inf[1])
        nodes = options[:node_array] & nodelist
        treated += nodes
        $clients << self.new(inf[0],inf[1],nodes)
      end
    else
      info = options[:servers][options[:chosen_server]]
      nodelist = get_nodelist(info[0],info[1])
      nodes = options[:node_array] & nodelist
      treated += nodes
      $clients << self.new(info[0],info[1],nodes)
    end

    # Check that every nodes was treated
    error("The nodes #{(options[:node_array] - treated).join(", ")} does not belongs to any server") unless treated.sort == options[:node_array].sort

    # Launch the deployment
    $threads = []
    $clients.each do |client|
      $threads << Thread.new do
        Thread.current[:client] = client
        client.run(options)
      end
    end
    $threads.each { |thread| thread.join }
  end

  def self.parse_options()
    raise
  end

  def self.check_options(options)
  end

  def connect()
    self.class.connect(@server,@port) do |client|
      yield(client)
    end
  end

  def self.connect(server,port)
    client = Net::HTTP.new(server, port)
    if HTTP_SECURE
      client.use_ssl = true
      client.verify_mode = OpenSSL::SSL::VERIFY_NONE
    end
    yield(client)
  end

  def run(options)
    raise
  end
end

