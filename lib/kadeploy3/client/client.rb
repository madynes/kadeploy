$kadeploy_confdir=ENV['KADEPLOY3_CONFIG_DIR']||'/etc/kadeploy3'

$kadeploy_logdir = nil
$files = []
$threads = []
$clients = []
$httpd = nil
$httpd_thread = nil
$killing = false
$debug_mode = nil
$debug_http = nil
$interactive = true
$http_user = nil
$http_password = nil

require 'thread'
require 'uri'
require 'optparse'
require 'net/http'
require 'net/https'
require 'timeout'
require 'tempfile'
require 'json'
require 'yaml'
require 'etc'
require 'io/console' if RUBY_VERSION >= '1.9'


module Kadeploy
CONTACT_EMAIL = "kadeploy3-users@lists.gforge.inria.fr"
USER = ENV['USER'] || ENV['USERNAME'] || Etc.getlogin || `id -nu`
STATUS_UPDATE_DELAY = 1
SLEEP_PITCH = 1
R_HOSTNAME = /\A[A-Za-z0-9\.\-\[\]\,]*\Z/


class Client
  @@terminal_width = nil
  attr_reader :name, :nodes

  def initialize(name,server,port,secure,auth_headers_prefix,nodes=nil)
    @name = name
    @server = server
    @port = port
    @secure = secure
    @auth_headers_prefix = auth_headers_prefix
    @nodes = nodes
  end

  def kill
  end

  def self.api_path(path=nil,kind=nil,*args)
    API.ppath(
      kind||service_name.downcase.gsub(/^ka/,'').to_sym,'',
      path||'',
      *args
    )
  end

  def api_path(path=nil,kind=nil,*args)
    API.ppath(
      kind||self.class.service_name.downcase.gsub(/^ka/,'').to_sym,
      File.join("#{(@secure ? 'https' : 'http')}://","#{@server}:#{@port}"),
      path||'',
      *args
    )
  end

  def self.error(msg='',code=1)
    unless $killing
      $stdin.cooked! if $stdin.respond_to?(:cooked!) and STDIN.tty? and !STDIN.closed?
      $stderr.puts msg if msg and !msg.empty?
      self.kill
      exit!(code||1)
    end
    raise
  end

  def error(msg='',code=1)
    self.class.error(debug(msg,false),code)
  end

  def self.kill()
    unless $killing
      $killing = true
      $threads.each do |thread|
        thread.kill unless thread == Thread.current
        #thread.join
      end

      $clients.each do |client|
        client.kill
      end

      if $httpd and $httpd_thread
        $httpd_thread.kill if $httpd_thread
        $httpd.kill if $httpd
      end

      $debug_mode.close if $debug_mode and $debug_mode != $stdout and !$debug_mode.closed?
      $debug_http.close if $debug_http and $debug_http != $stdout and !$debug_http.closed?

      $files.each do |file|
        file.close unless file.closed?
      end
    end
  end

  def self.load_configfile()
    configfile = File.join($kadeploy_confdir, "client.conf")
    configfile = File.join($kadeploy_confdir, "client_conf.yml") unless File.readable?(configfile)
    begin
      begin
        config = YAML.load_file(configfile)
      rescue Psych::SyntaxError => se
        error("Invalid YAML file '#{configfile}'\n#{se.message}")
      rescue ArgumentError => ae
        error("Invalid YAML file '#{configfile}' (#{ae.message})")
      rescue Errno::ENOENT
        error("File not found '#{configfile}'")
      end

      servers = {}
      cp = Configuration::Parser.new(config)

      cp.parse('servers',true,Array) do
        tmp = cp.value('auth_headers_prefix',String,'')
        tmp = nil if tmp.empty?
        servers[cp.value('name',String)] = [
          cp.value('hostname',String),
          cp.value('port',Fixnum),
          cp.value('secure',[TrueClass,FalseClass],true),
          tmp
        ]
      end
      servers['default'] = cp.value('default',String,nil,servers.keys)
    rescue ArgumentError => ae
      error("Error(#{configfile}) #{ae.message}")
    end

    error("No server specified in the configuration file") if servers.empty?

    return servers
  end

  def self.load_outputfile(file)
    begin
      File.open(file,'w'){}
    rescue
      error("Cannot create the file '#{file}'")
      return false
    end
  end

  def self.load_inputfile(file)
    if file.is_a?(IO) or check_file(file)
      file = File.new(file) unless file.is_a?(IO)
      file.readlines.collect{|v|v.chomp}.delete_if{|v|v=~/^\s*#.*$/ or v.empty?}
    else
      return false
    end
  end

  def self.load_envfile(envfile,srcfile)
    tmpfile = Tempfile.new("env_file")
    begin
      uri = URI(srcfile)
      if uri.scheme.nil? or uri.scheme.empty?
        uri.send(:set_scheme,'server')
        uri.send(:set_path,File.absolute_path(srcfile))
      end
      FetchFile[uri.to_s,true].grab(tmpfile.path)
      tmpfile.close
      uri = nil
    rescue KadeployError => ke
      tmpfile.unlink
      error(ke.message)
    end

    unless `file --mime-type --brief #{tmpfile.path}`.chomp == "text/plain"
      tmpfile.unlink
      error("The file #{srcfile} should be in plain text format")
    end

    begin
      ret = YAML.load_file(tmpfile.path)
    rescue Psych::SyntaxError => se
      error("Invalid YAML file '#{srcfile}'\n#{se.message.gsub(tmpfile.path,srcfile)}")
      tmpfile.unlink
    rescue ArgumentError => ae
      error("Invalid YAML file '#{srcfile}' (#{ae.message.gsub(tmpfile.path,srcfile)})")
      tmpfile.unlink
    rescue Errno::ENOENT
      tmpfile.unlink
      error("File not found '#{srcfile}'")
    end

    tmpfile.unlink

    begin
      Environment.new.load_from_desc(Marshal.load(Marshal.dump(ret)),[],USER,nil,false,$stdout)
    rescue KadeployError => ke
      msg = KadeployError.to_msg(ke.errno) || ''
      msg = "#{msg} (error ##{ke.errno})\n" if msg and !msg.empty?
      msg += ke.message if ke.message and !ke.message.empty?
      error(msg)
    end

    envfile.merge!(ret)
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
    file = nil
    if (param == "-")
      file = STDIN
    else
      return false unless check_file(param)
      file = File.new(param)
    end

    if (machines = load_inputfile(file))
      machines.each do |hostname|
        load_machine(nodelist,hostname)
      end
    else
      return false
    end
  end

  def self.load_custom_file(file)
    file = File.absolute_path(file)
    return false unless check_file(file)

    begin
      config = YAML.load_file(file)
    rescue Psych::SyntaxError => se
      error("Invalid YAML file '#{file}'\n#{se.message}")
    rescue ArgumentError => ae
      error("Invalid YAML file '#{file}' (#{ae.message})")
    rescue Errno::ENOENT
      return true
    end

    unless config.is_a?(Hash)
      $stderr.puts "Invalid file format '#{file}'"
      return false
    end

    config
  end

  def self.parse_machinefile(opt,options)
    add_opt(opt,"-f", "--file MACHINELIST", "A file containing a list of nodes (- means stdin)")  { |f|
      load_machinefile(options[:nodes], f)
    }
  end

  def self.parse_machine(opt,options)
    add_opt(opt,"-m", "--machine MACHINE", "The node to run on") { |m|
      load_machine(options[:nodes], m)
    }
  end

  def self.parse_env_user(opt,options)
    add_opt(opt,"-u", "--env-user USERNAME", /^\w+$/, "Specify the user that own the recorded environment") { |u|
      options[:env_user] = u
    }
  end

  def self.parse_user(opt,options)
    add_opt(opt,"-u", "--user USERNAME", /^\w+$/, "Specify the user") { |u|
      options[:user] = u
    }
  end

  def self.parse_env_name(opt,options)
    add_opt(opt,"-e", "--env-name ENVNAME", "Name of the recorded environment") { |n|
      options[:env_name] = n
      yield(n)
    }
  end

  def self.parse_env_version(opt,options)
    add_opt(opt,"--env-version NUMBER", /^\d+$/, "Version number of the recorded environment") { |n|
      options[:env_version] = n.to_i
    }
  end

  def self.parse_secure(opt,options)
    add_opt(opt,"--[no-]secure", "Use a secure connection to export files to the server") { |v|
      options[:secure] = v
    }
  end

  def self.check_file(file)
    if File.readable?(file)
      return true
    else
      error("The file #{file} cannot be read")
      return false
    end
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
      unreachables = []
      options[:servers].each_pair do |server,inf|
        next if server.downcase == "default"

        reachable = nil
        4.times do
          reachable = PortScanner::is_open?(inf[0], inf[1])
          break if reachable
          sleep 2
        end

        unless reachable
          debug("The #{server} server is unreachable")
          unreachables << server
        end
      end
      unreachables.each{|server| options[:servers].delete(server)}
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
        $stdout.puts "#{prefix if prefix}Kadeploy version: #{res.strip}"
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
        $stdout.puts "#{prefix if prefix}Kadeploy server configuration:"
        $stdout.puts "#{prefix if prefix}  Custom PXE boot method: #{res['pxe']}"
        $stdout.puts "#{prefix if prefix}  Automata configuration:"
        res['automata'].each_pair do |clname,macros|
          $stdout.puts "#{prefix if prefix}    #{clname}:"
          macros.each_pair do |name,steps|
            $stdout.puts "#{prefix if prefix}      #{name}: #{steps.collect{|s| s.values.join(',')}.join('; ')}"
          end
        end
        $stdout.puts "#{prefix if prefix}  Deployment environment:"
        $stdout.puts "#{prefix if prefix}    Supported file systems:"
        res['supported_fs'].each_pair do |clname,fslist|
          $stdout.puts "#{prefix if prefix}      #{clname}: #{fslist.join(',')}"
        end
        $stdout.puts "#{prefix if prefix}    Variables exported to custom scripts:"
        $stdout.puts print_arraystr(res['vars'],"#{prefix if prefix}      ")
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

  def self.debug(msg='',io=$stdout)
    io.puts msg
  end

  def debug(msg='',print=true,io=$stdout)
    if @name
      tmp = ''
      msg.each_line do |line|
        tmp << sprintf("%-10s%s","[#{@name}] ",line)
      end
      msg = tmp
    end

    if print
      io.puts msg
    else
      msg
    end
  end

  def self.add_localfiles(env)
    localfiles = []
    if env.is_a?(Array)
      env.each do |file|
        localfiles << localfile?(file)
      end
    elsif env.is_a?(Hash)
      localfiles << localfile?(env['image']['file'])
      localfiles << localfile?(env['preinstall']['archive']) if env['preinstall']
      if env['postinstalls'] and !env['postinstalls'].empty?
        env['postinstalls'].each do |postinstall|
          localfiles << localfile?(postinstall['archive'])
        end
      end
    else
      localfiles << localfile?(env)
    end
    localfiles.compact!

    unless localfiles.empty?
      localfiles.each do |file|
        error("Cannot read file '#{file}'") unless File.readable?(file)
        if File.directory?(file)
          Dir.foreach(file) do |fi|
            $files << File.new(File.join(file,fi)) unless ['.','..'].include?(fi)
          end
        else
          $files << File.new(file)
        end
      end
      true
    else
      false
    end
  end

  # returns absolute path if local, nil if not
  def self.localfile?(filename)
    uri = URI.parse(filename)
    if !uri.scheme or uri.scheme.empty? or uri.scheme.downcase == 'local'
      filename.replace(File.absolute_path(uri.path))
    end
  end

  # Serve files throught HTTP(s)
  def self.http_export_files(secure=false)
    return if !$files or $files.empty?
    httpd_init(secure)
    httpd_bind_files()
    httpd = httpd_run()
    httpd.url()
  end

  def self.service_name
    name.split('::').last.gsub(/Client$/,'')
  end

  def self.parse_uri(uri)
    uri = URI.parse(uri)
    [uri.host,uri.port,uri.path,uri.query]
  end

  def parse_uri(uri)
    self.class.parse_uri(uri)
  end

  def self.get(host,port,path,secure,headers=nil)
    ret = nil
    begin
      Timeout.timeout(32) do
        ret = HTTP::Client::get(host,port,path,secure,nil,nil,nil,headers)
      end
    rescue Timeout::Error
      error("Request timeout: cannot GET #{path} on #{host}:#{port}")
    rescue Errno::ECONNRESET
      error("The server refused the connection on #{host}:#{port}")
    rescue HTTP::ClientError => e
      error(e.message)
    end
    ret
  end

  def self.get2(options,path,params=nil)
    host,port,path,query = parse_uri(path)
    if query
      path = "#{path}?#{query}"
    elsif params
      path = HTTP::Client.path_params(path,params)
    end
    host = options[:server_host]  unless host
    port = options[:server_port]  unless port
    headers = {"#{options[:server_auth_http_prefix]}User" => USER}
    begin
      HTTP::Client::get(host,port,path,options[:server_secure],nil,nil,nil,headers)
    rescue HTTP::ClientError => e
      error(e.message,e.code)
    end
  end

  def get(uri,params=nil,accept_type=nil,parse=nil)
    host,port,path,query = parse_uri(uri)
    if query
      path = "#{path}?#{query}"
    elsif params
      path = HTTP::Client.path_params(path,params)
    end
    host = @server unless host
    port = @port unless port
    headers = {"#{@auth_headers_prefix}User" => USER}
    begin
      HTTP::Client::get(host,port,path,@secure,nil,accept_type,parse,headers)
    rescue HTTP::ClientError => e
      error(e.message,e.code)
    end
  end

  def post(uri,data,content_type=nil,accept_type=nil,parse=nil)
    host,port,path,query = parse_uri(uri)
    path = "#{path}?#{query}" if query
    host = @server unless host
    port = @port unless port
    headers = {"#{@auth_headers_prefix}User" => USER}
    begin
      HTTP::Client::post(host,port,path,data,@secure,content_type,accept_type,parse,headers)
    rescue HTTP::ClientError => e
      error(e.message,e.code)
    end
  end

  def put(uri,data,content_type=nil,accept_type=nil,parse=nil)
    host,port,path,query = parse_uri(uri)
    path = "#{path}?#{query}" if query
    host = @server unless host
    port = @port unless port
    headers = {"#{@auth_headers_prefix}User" => USER}
    begin
      HTTP::Client::put(host,port,path,data,@secure,content_type,accept_type,parse,headers)
    rescue HTTP::ClientError => e
      error(e.message,e.code)
    end
  end

  def delete(uri,data={},content_type=nil,accept_type=nil,parse=nil)
    host,port,path,query = parse_uri(uri)
    path = "#{path}?#{query}" if query
    host = @server unless host
    port = @port unless port
    headers = {"#{@auth_headers_prefix}User" => USER}
    begin
      HTTP::Client::delete(host,port,path,data,@secure,content_type,accept_type,parse,headers)
    rescue HTTP::ClientError => e
      error(e.message,e.code)
    end
  end

  def self.get_auth_headers_prefix(server,port,secure=true)
    tmp = get(server,port,'/auth_headers_prefix',secure)
    tmp.strip if tmp
  end

  def self.get_nodelist(server,port,secure,auth_headers_prefix)
    path = HTTP::Client.path_params('/nodes',{:user => USER,:list=>true})
    get(server,port,path,secure,{"#{auth_headers_prefix}User"=>USER})
  end

  def self.term_size()
    if !@@terminal_width
      if ENV['COLUMNS']
        @@terminal_width = ENV['COLUMNS'].to_i rescue 80
      elsif !STDIN.tty? or STDIN.closed?
        @@terminal_width = 80
      else
        if !(sizes = STDIN.winsize).empty?
          @@terminal_width = sizes[1]
        else
          @@terminal_width = 80
        end
      end
    end
    @@terminal_width
  end

  def self.print_optdesc(str,indentsize)
    return str.dup if term_size() <= 0
    ret = ''
    tmp = nil
    str.split(' ').each do |val|
      if tmp.nil?
        tmp = val
      elsif tmp.size + val.size + indentsize + 1 > term_size()
        ret << tmp
        ret << "\n#{([' ']*indentsize).join}"
        tmp = val
      else
        tmp << " #{val}"
      end
    end
    ret << tmp if tmp and !tmp.empty?
    ret
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
    $httpd = HTTPd::Server.new(nil,nil,secure)
  end

  def self.httpd_bind_files()
    $files.each do |file|
      $httpd.bind([:HEAD,:GET],"/#{Base64.urlsafe_encode64(file.path)}",:file,file)
    end
  end

  def self.httpd_run()
    $httpd_thread = Thread.new do
      $httpd.run
    end
    $httpd
  end

  def self.global_load_options()
    {
      :nodes => [],
      :get_version => false,
      :get_user_info => false,
      :dry_run => false,
      :multi_server => false,
      :chosen_server => nil,
      :server_host => nil,
      :server_port => nil,
      :server_secure => nil,
      :server_auth_http_prefix => nil,
    }
  end

  def self.add_opt(opt,*args,&block)
    desc = args.last
    tmp = print_optdesc(desc,opt.summary_width+opt.summary_indent.size+1)
    desc.clear rescue desc.gsub!(/.*/,'')
    desc << tmp
    opt.on(*args,&block)
  end

  def self.global_parse_options()
    options = load_options()
    opts = OptionParser::new do |opt|
      opt.summary_indent = "  "
      opt.summary_width = 28
      opt.banner = "Usage: #{$0.split('/')[-1]} [options]"
      opt.separator "Contact: #{CONTACT_EMAIL}"
      opt.separator ""
      opt.separator "Generic options:"
      opt.on("-h", "--help", "Show this message") do
        puts opts
        exit 0
      end
      add_opt(opt,"-v", "--version", "Get the server's version") {
        options[:get_version] = true
      }
      add_opt(opt,"-I", "--server-info", "Get information about the server's configuration") {
        options[:get_users_info] = true
      }
      add_opt(opt,"-M","--multi-server", "Activate the multi-server mode") {
        options[:multi_server] = true
      }
      add_opt(opt,"-H", "--[no-]debug-http", "Debug HTTP communications with the server (can be redirected to the fd #4)") { |v|
        if v
          $debug_http = IO.new(4) rescue $stdout unless $debug_http
        end
      }
      add_opt(opt,"-S","--server STRING", "Specify the Kadeploy server to use") { |s|
        options[:chosen_server] = s
      }
      add_opt(opt,"--[no-]dry-run", "Perform a dry run") { |v|
        options[:dry_run] = v
      }
      add_opt(opt,"--password [PASSWORD]", "Provide a password for HTTP Basic authentication (read from STDIN if not specified)") { |p|
        unless p
          error("Error: no password specified and invalid STDIN") if !STDIN.tty? or STDIN.closed?
          $stdout.write('Password: ')
          $stdout.flush
          if $stdin.respond_to?(:noecho)
            $stdin.noecho{|stdin| p = stdin.gets}
          else
            p = $stdin.gets
          end
          $stdout.puts
        end
        $http_user = USER.dup.freeze
        $http_password = p.dup.freeze
      }
      opt.separator ""
      yield(opt,options)
    end

    begin
      opts.parse!(ARGV)
    rescue OptionParser::ParseError
      error("Option parsing error: #{$!}")
      return false
    end

    return options
  end

  def self.parse_config(options)
    options[:servers] = load_configfile()
    options[:chosen_server] = options[:servers]['default'] unless options[:chosen_server]
    unless options[:servers][options[:chosen_server]]
      error("The server '#{options[:chosen_server]}' does not exist")
      return false
    end
    options[:server_host] = options[:servers][options[:chosen_server]][0]
    options[:server_port] = options[:servers][options[:chosen_server]][1]
    options[:server_secure] = options[:servers][options[:chosen_server]][2]
    options[:server_auth_http_prefix] = options[:servers][options[:chosen_server]][3]
    true
  end

  def self.init_params(options)
    ret = { }
    ret[:dry_run] = options[:dry_run] if options[:dry_run]
    ret
  end

  def self.prepare(options)
    init_params(options)
  end

  def self.launch()
    options = nil
    error() unless options = parse_options()
    # Hack to make the --version work even if the client is not installed
    if options[:get_version] and ENV['KADEPLOY3_VERSION']
      $stdout.puts ENV['KADEPLOY3_VERSION']
      exit 0
    end
    error() unless parse_config(options)
    error() unless check_servers(options)
    do_version(options) if options[:get_version]
    do_info(options) if options[:get_users_info]
    error() unless check_options(options)


    # Treatment of -m/--machine and -f/--file options
    if options[:nodes]
      if options[:nodes].empty?
        options[:nodes] = nil
      else
        options[:nodes].uniq!
      end
    end
    treated = []
    # Sort nodes from the list by server (if multiserver option is specified)
    nodes = nil
    if options[:multi_server]
      options[:servers].each_pair do |server,inf|
        next if server.downcase == 'default'
        inf[3] = get_auth_headers_prefix(inf[0],inf[1],inf[2]) unless inf[3]
        if options[:nodes]
          nodelist = get_nodelist(inf[0],inf[1],inf[2],inf[3])
          unless nodelist # Just in case a server give an empty answer
            error("Ignoring the server #{inf[0]} (empty answer)",false)
            next
          end
          # Strict check when working on multi-server
          nodes = options[:nodes] & nodelist
          next if nodes.empty? # it's useless to contact this server
          treated += nodes
        end
        $clients << self.new(server,inf[0],inf[1],inf[2],inf[3],nodes)
        break if options[:nodes] and treated.sort == options[:nodes].sort
      end
    else
      info = options[:servers][options[:chosen_server]]
      info[3] = get_auth_headers_prefix(info[0],info[1],info[2]) unless info[3]
      if options[:nodes]
        nodelist = get_nodelist(info[0],info[1],info[2],info[3])
        # Lazy check when not working on multi-server
        nodes = options[:nodes]
        options[:nodes].each do |node|
          if node =~ /\[.*\]/
            treated << node
          else
            treated << node unless nodelist.select{|n| n =~ /#{node}/}.empty?
          end
        end
      end
      $clients << self.new(nil,info[0],info[1],info[2],info[3],nodes)
    end
    options[:server_auth_http_prefix] = options[:servers][options[:chosen_server]][3]

    # Check that every nodes was treated
    error("The nodes #{(options[:nodes] - treated).join(", ")} does not belongs to any server") if options[:nodes] and treated.sort != options[:nodes].sort

    # Prepare parameters
    params = self.prepare(options)
    params = self.check_params(options,params)

    # Launch the deployment
    $clients.each do |client|
      $threads << Thread.new do
        Thread.current[:client] = client
        ret = client.run(options,params)
        client.result(options,ret) if ret and !options[:dry_run]
      end
    end

    status_thr = nil
    if $interactive and STDIN.tty? and !STDIN.closed?
      status_thr = Thread.new do
        last_status = Time.now
        while true
          STDIN.gets
          if Time.now - last_status > STATUS_UPDATE_DELAY
            $clients.each{|client| client.display_status()}
            last_status = Time.now
          end
        end
      end
    end

    $threads.each { |thread| thread.join }

    if status_thr
      status_thr.kill
      status_thr.join
    end

    if $httpd and $httpd_thread
      $httpd.kill if $httpd_thread.alive?
      $httpd_thread.join
    end

    $files.each do |file|
      file.close unless file.closed?
    end

    $debug_mode.close if $debug_mode and $debug_mode != $stdout and !$debug_mode.closed?
    $debug_http.close if $debug_http and $debug_http != $stdout and !$debug_http.closed?

    if options[:script]
      $stdout.puts "\nRunning #{options[:script]}\n"
      if system(options[:script])
        $stdout.puts "\nSuccess !"
      else
        $stdout.puts "\nFail !"
      end
    end
  end

  def display_status()
  end

  def self.parse_options()
    raise
  end

  def self.check_options(options)
  end

  def self.check_params(options,params)
    params
  end

  def run(options,params)
    raise
  end

  def result(options,ret)
  end

  def self.operation()
    raise
  end
end

class ClientWorkflow < Client
  attr_reader :wid

  def initialize(name,server,port,secure,auth_headers_prefix,nodes=nil)
    super(name,server,port,secure,auth_headers_prefix,nodes)
    @wid = nil
    @resources = nil
    @start_time = nil
  end

  def api_path(path=nil,kind=nil,*args)
    if @resources
      if @resources[path]
        @resources[path]
      else
        if path
          File.join(@resources['resource'],path,*args)
        else
          File.join(@resources['resource'],*args)
        end
      end
    else
      super(path,kind,*args)
    end
  end

  def kill
    super()
    begin
      delete(api_path()) if @wid
    rescue Exception
    end
  end

  def self.load_file(file)
    kind = (URI.parse(file).scheme||'local')
    case kind
    when 'local'
      if check_file(file)
        File.expand_path(file)
      else
        return false
      end
    when 'server'
      file
    when 'http','https'
      file
    else
      error("Invalid protocol '#{kind}'")
      return false
    end
  end

  def self.load_keyfile(file,val)
    if file and !file.empty?
      unless (val << load_file(file))
        return false
      end
    else
      authorized_keys = File.expand_path('~/.ssh/authorized_keys')
      if check_file(authorized_keys)
        val << authorized_keys
      else
        return false
      end
    end
  end

  def self.parse_okfile(opt,options)
    add_opt(opt,"-o", "--output-ok-nodes FILENAME", "File that will contain the nodes on which the operation has been correctly performed")  { |f|
      options[:nodes_ok_file] = f
      load_outputfile(f)
    }
  end

  def self.parse_kofile(opt,options)
    add_opt(opt,"-n", "--output-ko-nodes FILENAME", "File that will contain the nodes on which the operation has not been correctly performed")  { |f|
      options[:nodes_ko_file] = f
      load_outputfile(f)
    }
  end

  def self.parse_keyfile(opt,options)
    add_opt(opt,"-k", "--key [FILE]", "Public key to copy in the root's authorized_keys, if no argument is specified, use ~/.ssh/authorized_keys") { |f|
      options[:key] =  ''
      load_keyfile(f,options[:key])
    }
  end

  def self.parse_op_level(opt,options)
    add_opt(opt,"-l", "--op-level VALUE", ['soft','hard','very_hard'], "Operation\'s level (soft, hard, very_hard)") { |l|
      options[:level] = l.downcase
    }
  end

  def self.parse_debug(opt,options)
    add_opt(opt,"-d", "--[no-]debug-mode", "Activate the debug mode  (can be redirected to the fd #3)") { |v|
      options[:debug] = v
      if v
        $debug_mode = IO.new(3) rescue $stdout unless $debug_mode
      end
    }
  end

  def self.parse_verbose(opt,options)
    add_opt(opt,"-V", "--verbose-level VALUE", /^[0-5]$/, "Verbose level (between 0 to 5)") { |d|
      options[:verbose_level] = d.to_i
    }
  end

  def self.parse_block_device(opt,options)
    add_opt(opt,"-b", "--block-device BLOCKDEVICE", /^[\w\/]+$/, "Specify the block device to use") { |b|
      options[:block_device] = b
      options[:deploy_part] = '' unless options[:deploy_part]
    }
  end

  def self.parse_deploy_part(opt,options)
    add_opt(opt,"-p", "--partition-number NUMBER", /^\d*$/, "Specify the partition number to use") { |p|
      options[:deploy_part] = p
    }
  end

  def self.parse_vlan(opt,options)
    add_opt(opt,"--vlan VLANID", "Set the VLAN") { |id|
      options[:vlan] = id
    }
  end

  def self.parse_pxe_profile(opt,options)
    add_opt(opt,"-w", "--set-pxe-profile FILE", "Set the PXE profile (use with caution)") { |f|
      if check_file(f)
        options[:pxe_profile] = File.read(f)
      else
        return false
      end
    }
  end

  def self.parse_pxe_pattern(opt,options)
    add_opt(opt,"--set-pxe-pattern FILE", "Specify a file containing the substitution of a pattern for each node in the PXE profile (the NODE_SINGULARITY pattern must be used in the PXE profile)") { |f|
      if (lines = load_inputfile(f))
        options[:pxe_profile_singularities] = {}
        lines.each do |line|
          content = line.split(",")
          options[:pxe_profile_singularities][content[0]] = content[1].strip
        end
      else
        return false
      end
    }
  end

  def self.parse_pxe_files(opt,options)
    add_opt(opt,"-x", "--upload-pxe-files FILES", Array, "Upload a list of files (file1,file2,file3) to the PXE repository. Those files will then be available with the prefix FILES_PREFIX-- ") { |fs|
      fs.each do |file|
        return false unless (filename = load_file(File.expand_path(file)))
        options[:pxe_files] << filename
      end
    }
  end

  def self.parse_wid(opt,options)
    add_opt(opt,"--write-workflow-id FILE", "Write the workflow id in a file") { |f|
      options[:wid_file] = f
      load_outputfile(f)
    }
  end

  def self.parse_scriptfile(opt,options)
      add_opt(opt,"-s", "--script FILE", "Execute a script at the end of the operation") { |f|
      if check_file(f)
        if File.stat(f).executable?
          options[:script] = File.expand_path(f)
        else
          error("The file #{f} must be executable")
          return false
        end
      else
        return false
      end
      }
  end

  def self.parse_timeout_reboot(opt,options)
    add_opt(opt,"--reboot-classical-timeout VALUE", "Overload the default timeout for classical reboots (a ruby expression can be used, 'n' will be replaced by the number of nodes)") { |t|
      options[:reboot_classical_timeout] = t
    }
  end

  def self.parse_wait(opt,options)
    add_opt(opt,"--[no-]wait", "Wait the end of the operation, set by default") { |v|
      options[:wait] = v
    }
  end

  def self.parse_force(opt,options)
    add_opt(opt,"--[no-]force", "Allow to deploy even on the nodes tagged as currently used (use this only if you know what you do)") {
      options[:force] = true
    }
  end

  def self.parse_breakpoint(opt,options)
    add_opt(opt,"--breakpoint STEP", /^\w+(?::\w+)?$/, "Set a breakpoint just before lauching the given micro-step, the syntax is macrostep:microstep (use this only if you know what you do)") { |s|
      options[:breakpoint] = s
    }
  end

  def self.parse_custom_ops(opt,options)
    add_opt(opt,"--custom-steps FILE", "Add some custom operations defined in a file") { |file|
      options[:custom_operations] = load_custom_file(file)
      return false unless options[:custom_operations]
    }
  end

  def self.parse_hook(opt,options)
    add_opt(opt,"--[no-]hook", "Launch server's hook at the end of operation, disabled by default") { |h|
      options[:hook] = h
    }
  end

  def self.global_load_options()
    super.merge(
      {
        :debug => nil,
        :verbose_level => nil,
        :nodes_ok_file => nil,
        :nodes_ko_file => nil,
        :wid_file => nil,
        :script => nil,
        :wait => true,
        :force => false,
        :breakpoint => nil,
        :custom_operations => nil,
      }
    )
  end

  def self.global_parse_options()
    super do |opt,options|
      #opt.separator ""
      #opt.separator "Workflow options:"
      parse_debug(opt,options)
      parse_machinefile(opt,options)
      parse_machine(opt,options)
      parse_kofile(opt,options)
      parse_okfile(opt,options)
      parse_scriptfile(opt,options)
      parse_verbose(opt,options)
      parse_wid(opt,options)
      parse_wait(opt,options)
      parse_force(opt,options)
      parse_breakpoint(opt,options)
      parse_custom_ops(opt,options)
      parse_hook(opt,options)
      opt.separator ""
      yield(opt,options)
    end
  end

  def self.check_options(options)
    if options[:nodes].empty?
      error("No node is chosen")
      return false
    end

    if options[:nodes_ok_file] and options[:nodes_ok_file] == options[:nodes_ko_file]
      error("The files used for the output of the OK and the KO nodes cannot be the same")
      return false
    end

    unless options[:wait]
      if options[:nodes_ok_file] or options[:nodes_ko_file]
        error("-o/--output-ok-nodes and/or -n/--output-ko-nodes cannot be used with --no-wait")
        return false
      end
    end

    if options[:verbose_level] and !(1..5).include?(options[:verbose_level])
      error("Invalid verbose level")
      return false
    end

    true
  end

  def self.init_params(options)
    ret = super(options)

    ret[:debug] = options[:debug] if options[:debug]
    ret[:verbose_level] = options[:verbose_level] if options[:verbose_level]
    ret[:force] = options[:force] if options[:force]
    ret[:breakpoint] = options[:breakpoint] if options[:breakpoint]
    ret[:custom_operations] = options[:custom_operations] if options[:custom_operations]
    ret[:hook] = options[:hook] if options[:hook]

    ret
  end

  def self.prepare(options)
    params = super(options)
    if options[:custom_operations]
      options[:custom_operations].each_pair do |macro,micros|
        micros.each_pair do |micro,ops|
          ops.each_pair do |op,acts|
            acts.each do |act|
              add_localfiles(act['file']) if act['file']
            end
          end
        end
      end
    end

    params
  end

  def self.check_params(options,params)
    params = super(options,params)

    # Serve local files throught HTTP(s)
    params[:client] = http_export_files(options[:secure]) unless $files.empty?

    # Check if some files are local while the option no-wait is used
    if !options[:wait] and !$files.empty?
      error("Cannot use --no-wait since some files have to be exported to the server:\n  #{$files.collect{|f|f.path}.join("\n  ")}")
    end

    params
  end

  def run(options,params)
    # Launch the workflow
    run_workflow(options,params)
  end

  def run_workflow(options,params,submit_method=:post)
    params[:nodes] = nodes()

    # Launch the operation
    ret = send(submit_method,api_path(),params)
    return if options[:dry_run]

    @wid = ret['wid']
    @resources = ret['resources']
    @start_time = Time.now.to_i
    File.open(options[:wid_file],'w'){|f| f.write @wid} if options[:wid_file]

    if options[:wait]
      debug "#{self.class.operation()}#{" ##{@wid}" if @wid} started\n"

      dbg = nil
      out = []

      res = nil
      begin
        res = get(api_path('resource'))

        yield(res) if block_given?

        if res['logs']
          log = get(api_path('log'))
          out += log.split("\n")
        end

        if options[:debug] and res['debugs']
          dbg = get(api_path('debug')) if options[:debug]
          dbg = dbg.split("\n")
          dbg.delete_if{|line| line.empty?}
          dbg.collect!{|line| "#{line.split('|')[0]}|[dbg] #{line.split('|')[1]}" rescue "[dbg] #{line}"}
          if $debug_mode and $debug_mode != $stdout
            dbg.sort_by!{|line| (line.split("|")[0] rescue '0').to_f}
            dbg.collect!{|line| line.split("|")[1] rescue line }
            debug(dbg.join("\n"),true,$debug_mode)
          else
            out += dbg
          end
          dbg.clear rescue dbg.gsub!(/.*/,'')
        end

        unless out.empty?
          out.sort_by!{|line| (line.split("|")[0] rescue '0').to_f}
          out.collect!{|line| line.split("|")[1] rescue line }
          debug out.join("\n")
          out.clear rescue out.gsub!(/.*/,'')
        end

        sleep SLEEP_PITCH
      end until res['done']

      get(api_path('error')) if res['error']

      debug "#{self.class.operation()}#{" ##{@wid}" if @wid} done\n\n"

      states = get(api_path('state'))
      delete(api_path()) if @wid
      @resources = nil

      [ res, states ]
    else
      debug "#{@wid} #{@resources['resource']}\n"
      nil
    end
  end

  def result(options,ret)
    res,states = ret
    unless res['error']
      # Success
      if res['nodes']['ok'] and !res['nodes']['ok'].empty?
        debug "The #{self.class.operation().downcase} is successful on nodes"
        debug res['nodes']['ok'].join("\n")
        File.open(options[:nodes_ok_file],'a+') do |f|
          f.puts res['nodes']['ok'].join("\n")
        end if options[:nodes_ok_file]
      end

      # Fail
      if res['nodes']['ko'] and !res['nodes']['ko'].empty?
        debug "The #{self.class.operation().downcase} failed on nodes"
        res['nodes']['ko'].each do |node|
          debug "#{node} (#{states[node]['error'] if states[node]})\n"
        end
        File.open(options[:nodes_ko_file],'a+') do |f|
          f.puts res['nodes']['ko'].join("\n")
        end if options[:nodes_ko_file]
      end
    end
  end

  def display_status_cluster(stat,prefix='')
    stat.each_pair do |macro,micros|
      if micros.is_a?(Hash)
        micros.each_pair do |micro,status|
          if status.is_a?(Hash)
            status['nodes'].each_pair do |state,nodes|
              unless nodes.empty?
                debug "#{prefix}  [#{macro.to_s}-#{micro.to_s}] ~#{status['time']}s (#{state.to_s})"
                debug "#{prefix}     #{nodes.join("\n#{prefix}     ")}"
              end
            end
          elsif status.is_a?(Array)
            debug "#{prefix}  [#{macro.to_s}-#{micro.to_s}]"
            debug "#{prefix}    #{status.join("\n#{prefix}    ")}"
          end
        end
      elsif micros.is_a?(Array)
        debug "#{prefix}  [#{macro.to_s}]"
        debug "#{prefix}    #{micros.join("\n#{prefix}    ")}"
      end
    end
  end

  def display_status()
    debug "---"
    if !@wid
      debug "#{self.class.operation()} did not start at the moment"
    elsif @wid and !@resources
      debug "#{self.class.operation()} status (#{Time.now.to_i - @start_time}s): done"
    else
      stats = get(@resources['status'])

      if stats.empty?
        debug "#{self.class.operation()} did not start at the moment"
      else
        debug "#{self.class.operation()} status (#{Time.now.to_i - @start_time}s):"
        if stats.size == 1
          display_status_cluster(stats[stats.keys[0]])
        else
          stats.each_pair do |clname,stat|
            debug "  [#{clname}]"
            display_status_cluster(stat,'  ')
          end
        end
      end
    end
    debug "---"
  end
end

end
