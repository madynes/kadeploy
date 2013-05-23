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

class HTTPClient
  def self.error(msg='',abrt = true)
    $stderr.puts msg if msg and !msg.empty?
    exit 1 if abrt
  end

  def self.connect(server,port)
    begin
      client = Net::HTTP.new(server, port)
      if HTTP_SECURE
        client.use_ssl = true
        client.verify_mode = OpenSSL::SSL::VERIFY_NONE
      end
      yield(client)
    rescue Errno::ECONNREFUSED
      error("Connection atempt refused by the server")
    end
  end

  def self.request(server,port,path)
    res = nil
    connect(server,port) do |client|
      response = yield(client)
      if response.is_a?(Net::HTTPOK)
        if response['Content-Type'] == 'application/json'
          res = JSON::load(response.body)
        else
          error("Invalid server response (Content-Type: '#{response['Content-Type']}')")
        end
      else
        case response.code.to_i
        when 400
          error("[#{name.gsub(/Client/,'')} Error ##{response['X-Application-Error-Code']}]\n#{response.body}")
        when 500
          error("[Internal Server Error]\n#{response.body}")
        else
          error(
            "[HTTP Error ##{response.code}]\n"\
            "-----------------\n"\
            "#{response.body}\n"\
            "-----------------"
          )
        end
      end
      #yield(res) if block_given?
    end
    res
  end

  def self.get(server,port,path)
    res = request(server,port,path) { |client| client.get(path) }
    if block_given?
      yield(res)
      res = nil
    end
    res
  end

  def self.post(server,port,path,data,content_type='application/json')
    res = request(server,port,path) do |client|
      client.post(path,data,
        {
          'Content-Type' => content_type,
          'Content-Length' => data.size.to_s,
        }
      )
    end
    if block_given?
      yield(res)
      res = nil
    end
    res
  end

  def self.delete(server,port,path)
    res = request(server,port,path) { |client| client.delete(path) }
    if block_given?
      yield(res)
      res = nil
    end
    res
  end
end

class Client
  def initialize(server,port,nodes)
    @server = server
    @port = port
    @wid = nil
    @url = nil
    @nodes = nodes
  end

  def kill
    delete(api_path().to_s)
  end

  def api_path(path='',api_dir=API_DIR)
    #tmp = File.join("http#{'s' if HTTP_SECURE}://#{@server}:#{@port}")
    if @url
      File.join(@url,path)
    else
      File.join(api_dir,path)
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
      error("Error(#{configfile}) #{ae.message}")
    end

    error("No server specified in the configuration file") if servers.empty?

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


  def get(path)
    HTTPClient::get(@server,@port,path)
  end

  def post(path,data,content_type='application/json')
    HTTPClient::post(@server,@port,path,data,content_type)
  end

  def delete(path)
    HTTPClient::delete(@server,@port,path)
  end

  def self.get_nodelist(server,port)
    nodelist = nil
    begin
      Timeout.timeout(8) do
        nodelist = HTTPClient::get(server,port,'/nodes')
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

  def self.launch()
    options = nil
    error() unless options = parse_options()
    error() unless check_options(options)

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

    # Treatment of -v/--version option
    if options[:get_version]
      print = Proc.new do |res,prefix|
        puts "#{prefix if prefix}Kadeploy version: #{res['version']}"
      end
      if options[:multi_server]
        options[:servers].each_pair do |server,inf|
          next if server.downcase == "default"
          get(inf[0],inf[1],'/version') do |res|
            print.call(res,"(#{inf[0]}) ")
          end
        end
      else
        info = options[:servers][options[:chosen_server]]
        get(info[0],info[1],'/version') do |res|
          print.call(res)
        end
      end
      exit 0
    end

    # Treatment of -i/--server-info option
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
          get(inf[0],inf[1],'/info') do |res|
            print.call(res,"(#{inf[0]}) ")
          end
        end
      else
        info = options[:servers][options[:chosen_server]]
        get(info[0],info[1],'/info') do |res|
          print.call(res)
        end
      end
      exit 0
    end


    # Treatment of -m/--machine and -f/--file options
    $clients = []
    treated = []
    # Sort nodes from the list by server (if multiserver option is specified)
    if options[:multi_server]
      options[:servers].each_pair do |server,inf|
        next if server.downcase == 'default'
        nodelist = get_nodelist(inf[0],inf[1])
        nodes = options[:nodes] & nodelist
        treated += nodes
        $clients << self.new(inf[0],inf[1],nodes)
      end
    else
      info = options[:servers][options[:chosen_server]]
      nodelist = get_nodelist(info[0],info[1])
      nodes = options[:nodes] & nodelist
      treated += nodes
      $clients << self.new(info[0],info[1],nodes)
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
  end

  def self.parse_options()
    raise
  end

  def self.check_options(options)
  end

  def run(options)
    raise
  end
end

