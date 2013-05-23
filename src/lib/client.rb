# Kadeploy 3.1
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2011
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

CONTACT_EMAIL = "kadeploy3-users@lists.gforge.inria.fr"
USER = `id -nu`.strip

STATUS_UPDATE_DELAY = 2
R_HOSTNAME = /\A[A-Za-z0-9\.\-\[\]\,]*\Z/

$kadeploy_config_directory=ENV['KADEPLOY3_CONFIG_DIR']||'/etc/kadeploy3'

$kadeploy_logdir = nil
$files = []
$httpd = nil
$httpd_thread = nil

require 'configparser'
require 'port_scanner'
require 'fetchfile'
require 'environment'
require 'http'
require 'httpd'

require 'thread'
require 'uri'
require 'net/http'
require 'net/https'
require 'timeout'
require 'json'
require 'yaml'


class Client
  attr_reader :wid

  def initialize(server,port,nodes,secure=false)
    @server = server
    @port = port
    @secure = secure
    @wid = nil
    @resources = nil
    @nodes = nodes
  end

  def kill
    delete(api_path())
  end

  def api_path(path='',api_dir=API_DIR)
    if @resources
      if !path or path.empty?
        @resources['resource']
      elsif @resources[path]
        @resources[path]
      else
        File.join(@resources['resource'],path)
      end
    else
      File.join("#{(@secure ? 'https' : 'http')}://","#{@server}:#{@port}",api_dir,path)
    end
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
      #thread.join
    end

    $clients.each do |client|
      client.kill
    end

    if $httpd and $httpd_thread
      $httpd_thread.kill if $httpd_thread
      $httpd.kill if $httpd
    end

    $files.each do |file|
      file.close unless file.closed?
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
          cp.value('port',Fixnum),
          cp.value('secure',[TrueClass,FalseClass])
        ]
      end
      servers['default'] = cp.value('default',String,nil,servers.keys)
    rescue ArgumentError => ae
      error("Error(#{configfile}) #{ae.message}")
    end

    error("No server specified in the configuration file") if servers.empty?

    return servers
  end

  def self.load_envfile(srcfile)
    tmpfile = Tempfile.new("env_file")
    begin
      uri = URI(File.absolute_path(srcfile))
      uri.scheme = 'server'
      uri.send(:set_host, '')
      FetchFile[uri.to_s,KadeployError::LOAD_ENV_FROM_DESC_ERROR].grab(tmpfile.path)
      tmpfile.close
      uri = nil
    rescue KadeployError => ke
      msg = KadeployError.to_msg(ke.errno) || ''
      msg = "#{msg} (error ##{ke.errno})\n" if msg and !msg.empty?
      msg += ke.message if ke.message and !ke.message.empty?
      tmpfile.unlink
      error(msg)
    end

    unless `file --mime-type --brief #{tmpfile.path}`.chomp == "text/plain"
      tmpfile.unlink
      error("The file #{srcfile} should be in plain text format")
    end

    begin
      ret = YAML.load_file(tmpfile.path)
    rescue ArgumentError
      tmpfile.unlink
      error("Invalid YAML file '#{srcfile}'")
    rescue Errno::ENOENT
      tmpfile.unlink
      error("File not found '#{srcfile}'")
    end

    tmpfile.unlink

    begin
      EnvironmentManagement::Environment.new.load_from_desc(Marshal.load(Marshal.dump(ret)),[],USER,nil,false)
    rescue KadeployError => ke
      msg = KadeployError.to_msg(ke.errno) || ''
      msg = "#{msg} (error ##{ke.errno})\n" if msg and !msg.empty?
      msg += ke.message if ke.message and !ke.message.empty?
      error(msg)
    end

    ret
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
      file = File.absolute_path(param)
      if File.readable?(file) then
        IO.readlines(file).sort.uniq.each do |hostname|
          load_machine(nodelist,hostname)
        end
      else
        error("The file #{file} cannot be read")
      end
    end
    return true
  end

  def self.load_custom_ops_file(file)
    file = File.absolute_path(file)
    if not File.readable?(file) then
      error("The file #{file} cannot be read")
      return false
    end

    begin
      config = YAML.load_file(file)
    rescue ArgumentError
      $stderr.puts "Invalid YAML file '#{file}'"
      return false
    rescue Errno::ENOENT
      return true
    end

    unless config.is_a?(Hash)
      $stderr.puts "Invalid file format '#{file}'"
      return false
    end
    #example of line: macro_step,microstep@cmd1%arg%dir,cmd2%arg%dir,...,cmdN%arg%dir
    ret = { :operations => {}, :overrides => {}}
    customops = ret[:operations]
    customover = ret[:overrides]

    config.each_pair do |macro,micros|
      unless micros.is_a?(Hash)
        $stderr.puts "Invalid file format '#{file}'"
        return false
      end
      unless check_macrostep_instance(macro)
        error("[#{file}] Invalid macrostep '#{macro}'")
        return false
      end
      customops[macro.to_sym] = {} unless customops[macro.to_sym]
      micros.each_pair do |micro,operations|
        unless operations.is_a?(Hash)
          $stderr.puts "Invalid file format '#{file}'"
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

  def self.check_servers(options)
    unless options[:chosen_server].empty? then
      unless options[:servers][options[:chosen_server]]
        error("The #{options[:chosen_server]} server is not defined in the configuration: #{(options[:servers].keys - ["default"]).join(", ")} values are allowed")
        return false
      end
    end

    # Check if servers specified in the config file are reachable
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

    return true
  end

  # Treatment of -v/--version option
  def self.do_version(options)
    if options[:get_version]
      print = Proc.new do |res,prefix|
        puts "#{prefix if prefix}Kadeploy version: #{res['version']}"
      end
      if options[:multi_server]
        options[:servers].each_pair do |server,inf|
          next if server.downcase == "default"
          print.call(get(inf[0],inf[1],'/version',inf[2]),"(#{inf[0]}) ")
        end
      else
        info = options[:servers][options[:chosen_server]]
        print.call(get(info[0],info[1],'/version',info[2]))
      end
      exit 0
    end
  end

  # Treatment of -i/--server-info option
  def self.do_info(options)
    if options[:get_users_info]
      print = Proc.new do |res,prefix|
        puts "#{prefix if prefix}Kadeploy server configuration:"
        puts "#{prefix if prefix}  Custom PXE boot method: #{res['pxe']}"
        puts "#{prefix if prefix}  Deployment environment:"
        puts "#{prefix if prefix}    Supported file systems:"
        res['supported_fs'].each_pair do |clname,fslist|
          puts "#{prefix if prefix}      #{clname}: #{fslist.join(',')}"
        end
        puts "#{prefix if prefix}    Variables exported to custom scripts:"
        puts print_arraystr(res['vars'],"#{prefix if prefix}      ")
      end

      if options[:multi_server]
        options[:servers].each_pair do |server,inf|
          next if server.downcase == "default"
          print.call(get(inf[0],inf[1],'/info',inf[2]),"(#{inf[0]}) ")
        end
      else
        info = options[:servers][options[:chosen_server]]
        print.call(get(info[0],info[1],'/info',info[2]))
      end
      exit 0
    end
  end

  # Checks if the environment contains local files
  def get_localfiles(env)
    localfiles = []
    localfiles << localfile?(env['image']['file'])
    localfiles << localfile?(env['preinstall']['archive']) if env['preinstall']
    if env['postinstalls'] and !env['postinstalls'].empty?
      env['postinstalls'].each do |postinstall|
        localfiles << localfile?(postinstall['archive'])
      end
    end
    localfiles.compact!
    localfiles
  end

  # returns absolute path if local, nil if not
  def localfile?(filename)
    uri = URI.parse(filename)
    if !uri.scheme or uri.scheme.empty? or uri.scheme.downcase == 'local'
      filename.replace(File.absolute_path(uri.path))
    end
  end

  # Serve files throught HTTP(s)
  def http_export_files(files,secure=false)
    return if !files or files.empty?
    self.class.httpd_init(secure)
    self.class.httpd_bind_files(files)
    httpd = self.class.httpd_run()
    httpd.url()
  end

  def self.service_name
    name.gsub(/Client$/,'')
  end

  def parse_uri(uri)
    uri = URI.parse(uri)
    [uri.host,uri.port,uri.path]
  end

  def self.get(host,port,path,secure=false)
    HTTPClient::get(host,port,path,secure,service_name())
  end

  def get(uri)
    host,port,path = parse_uri(uri)
    host = @server unless host
    port = @port unless port
    HTTPClient::get(host,port,path,@secure,self.class.service_name)
  end

  def post(uri,data,content_type='application/json')
    host,port,path = parse_uri(uri)
    host = @server unless host
    port = @port unless port
    HTTPClient::post(host,port,path,data,@secure,content_type,self.class.service_name)
  end

  def put(uri,data,content_type='application/json')
    host,port,path = parse_uri(uri)
    host = @server unless host
    port = @port unless port
    HTTPClient::put(host,port,path,data,@secure,content_type,self.class.service_name)
  end

  def delete(uri)
    host,port,path = parse_uri(uri)
    host = @server unless host
    port = @port unless port
    HTTPClient::delete(host,port,path,@secure,self.class.service_name)
  end

  def self.get_nodelist(server,port,secure=true)
    nodelist = nil
    begin
      Timeout.timeout(8) do
        nodelist = HTTPClient::get(server,port,'/nodes',secure)
      end
    rescue Timeout::Error
      error("Cannot check the nodes on the #{server} server")
    rescue Errno::ECONNRESET
      error("The #{server} server refused the connection on port #{port}")
    end
    nodelist
  end

  def self.print_arraystr(arr,prefix=nil)
    ret = ''
    prefix = prefix || ''
    colsize = (ENV['COLUMNS']||80).to_i
    tmp = nil
    arr.each do |val|
      if tmp.nil?
        tmp = prefix.dup
        tmp << val
      elsif tmp.size + val.size + 2 > colsize
        ret << tmp
        ret << "\n"
        tmp = prefix.dup
        tmp << val
      else
        tmp << ", #{val}"
      end
    end
    ret << tmp if tmp and !tmp.empty? and tmp != prefix
    ret
  end

  def self.httpd_init(secure=false)
    $httpd = HTTPd.new(nil,nil,secure)
  end

  def self.httpd_bind_files(files)
    files.each do |file|
      error("Cannot read file '#{file}'") unless File.readable?(file)
      obj = File.new(file)
      $files << obj
      $httpd.bind([:HEAD,:GET],"/#{Base64.urlsafe_encode64(file)}",:file,obj)
    end
  end

  def self.httpd_run()
    $httpd_thread = Thread.new do
      $httpd.run
    end
    $httpd
  end

  def self.launch()
    options = nil
    error() unless options = parse_options()
    error() unless check_servers(options)
    do_version(options) if options[:get_version]
    do_info(options) if options[:get_users_info]
    error() unless check_options(options)


    # Treatment of -m/--machine and -f/--file options
    $clients = []

    options[:nodes] = [] unless options[:nodes]
    treated = []
    # Sort nodes from the list by server (if multiserver option is specified)
    if options[:multi_server]
      options[:servers].each_pair do |server,inf|
        next if server.downcase == 'default'
        nodelist = get_nodelist(inf[0],inf[1],inf[2])
        nodes = options[:nodes] & nodelist
        treated += nodes
        $clients << self.new(inf[0],inf[1],nodes,inf[2])
      end
    else
      info = options[:servers][options[:chosen_server]]
      nodelist = get_nodelist(info[0],info[1],info[2])
      nodes = options[:nodes] & nodelist
      treated += nodes
      $clients << self.new(info[0],info[1],nodes,info[2])
    end

    # Check that every nodes was treated
    error("The nodes #{(options[:nodes] - treated).join(", ")} does not belongs to any server") unless treated.sort == options[:nodes].sort

    # Launch the deployment
    $threads = []
    $clients.each do |client|
      $threads << Thread.new do
        Thread.current[:client] = client
        client.run(options)
      end
    end
    $threads.each { |thread| thread.join }

    if $httpd and $httpd_thread
      $httpd.kill if $httpd_thread.alive?
      $httpd_thread.join
    end
  end

  def self.parse_options()
    raise
  end

  def self.check_options(options)
  end

  def run(options)
    raise
  end

  def self.operation()
    raise
  end

  def start!()
    puts "#{self.class.operation()}#{" ##{@wid}" if @wid} started"
  end

  def done!()
    puts "#{self.class.operation()}#{" ##{@wid}" if @wid} done"
  end
end

