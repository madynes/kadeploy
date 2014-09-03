require 'optparse'
require 'ostruct'
require 'fileutils'
require 'resolv'
require 'ipaddr'
require 'yaml'
require 'webrick'
require 'socket'

module Kadeploy

module Configuration
  KADEPLOY_PORT = 25300

  module ConfigFile
    def file()
      raise
    end

    def duplicate
      Marshal.load(Marshal.dump(self))
    end

    def free
      self.instance_variables.each do |v|
        obj = self.instance_variable_get(v)
        next if obj.hash == hash()
        obj.free if obj.respond_to?(:free)
        obj.clear if obj.respond_to?(:clear)
        self.instance_variable_set(v,nil)
      end
      if self.respond_to?(:each)
        self.each do |obj|
          next if obj.hash == hash()
          obj.free if obj.respond_to?(:free)
          obj.clear if obj.respond_to?(:clear)
        end
      end
      if self.respond_to?(:each_value)
        self.each_value do |obj|
          next if obj.hash == hash()
          obj.free if obj.respond_to?(:free)
          obj.clear if obj.respond_to?(:clear)
        end
      end
      self.clear if self.respond_to?(:clear)
      self
    end
  end

  class Config
    VERSION_FILE = File.join($kadeploy_confdir, "version")

    attr_reader :common, :clusters, :caches, :static

    def initialize(config=nil,caches=nil)
      if config.nil?
        sanity_check()

        version = nil
        begin
          version = File.read(VERSION_FILE).strip
        rescue Errno::ENOENT
          raise ArgumentError.new("File not found '#{VERSION_FILE}'")
        end

        # Common
        @common = CommonConfig.new(version)
        @static = @common.load
        res = (!@static.nil? and @static != false)

        # Clusters
        @clusters = ClustersConfig.new
        res = res && @clusters.load(@common)

        # Commands
        res = res && CommandsConfig.new.load(@common)

        if res
          # Caches
          if caches
            @caches = caches
          else
            @caches = load_caches()
          end

          @static.freeze
          @caches.freeze if @caches
        else
          raise KadeployError.new(APIError::BAD_CONFIGURATION,nil,
            "Problem in configuration")
        end
      else
        @common = config.common.duplicate
        @clusters = config.clusters.duplicate
        @caches = config.caches
        @static = config.static
      end
    end

    def static_values
      ret = @static.dup
      ret[:private_key] = ret[:private_key].to_der if ret[:private_key]
      ret[:cert] = ret[:cert].to_der if ret[:cert]
      ret
    end

    def duplicate()
      Config.new(self)
    end

    def free()
      @common.free if @common
      @common = nil
      @clusters.free if @clusters
      @clusters = nil
      @caches = nil
      @static = nil
    end

    def self.dir()
      $kadeploy_confdir
    end

    private
    # Perform a test to check the consistancy of the installation
    def sanity_check()
      files = [
        CommonConfig.file,
        ClustersConfig.file,
        CommandsConfig.file,
        VERSION_FILE
      ]

      files.each do |file|
        unless File.readable?(file)
          $stderr.puts "The #{file} file cannot be read"
          raise KadeployError.new(APIError::BAD_CONFIGURATION,nil,
            "Unsane configuration")
        end
      end
    end

    def load_caches()
      ret = {}
      if @static[:caches] and @static[:caches][:global]
        ret[:global] = Cache.new(
          @static[:caches][:global][:directory],
          @static[:caches][:global][:size],
          CacheIndexPVHash,true,true
        )
      end

      if @static[:caches] and @static[:caches][:netboot]
        ret[:netboot] = Cache.new(
          @static[:caches][:netboot][:directory],
          @static[:caches][:netboot][:size],
          CacheIndexPath,false,false
        )
      end

      ret
    end
  end

  class CommonConfig
    include ConfigFile

    def self.file()
      file = File.join($kadeploy_confdir, "server.conf")
      unless File.readable?(file)
        file = File.join($kadeploy_confdir, "server_conf.yml")
        $stderr.puts "Warning using a deprecated configuration file, consider to rename it to 'server.conf'"
      end
      file
    end

    attr_reader :cache
    attr_reader :verbose_level
    attr_reader :pxe
    attr_reader :db_kind
    attr_reader :deploy_db_host
    attr_reader :deploy_db_name
    attr_reader :deploy_db_login
    attr_reader :deploy_db_passwd
    attr_reader :rights_kind
    attr_reader :nodes
    attr_reader :taktuk_connector
    attr_reader :taktuk_tree_arity
    attr_reader :taktuk_outputs_size
    attr_reader :taktuk_auto_propagate
    attr_reader :tarball_dest_dir
    attr_reader :kadeploy_tcp_buffer_size
    attr_reader :max_preinstall_size
    attr_reader :max_postinstall_size
    attr_reader :ssh_port
    attr_reader :test_deploy_env_port
    attr_reader :environment_extraction_dir
    attr_reader :log_to_db
    attr_reader :dbg_to_file
    attr_reader :dbg_to_file_level
    attr_reader :purge_deployment_timer
    attr_reader :rambin_path
    attr_reader :mkfs_options
    attr_reader :tar_options
    attr_reader :bt_tracker_ip
    attr_reader :bt_download_timeout
    attr_reader :almighty_env_users
    attr_reader :version
    attr_reader :end_of_deploy_hook
    attr_reader :end_of_reboot_hook
    attr_reader :end_of_power_hook
    attr_reader :vlan_hostname_suffix
    attr_reader :set_vlan_cmd
    attr_reader :kastafior
    attr_reader :kascade
    attr_reader :kascade_options
    attr_reader :secure_client
    attr_reader :autoclean_threshold
    attr_reader :cmd_ext

    # Constructor of CommonConfig
    #
    # Arguments
    # * nothing
    # Output
    # * nothing
    def initialize(version=nil)
      @version = version
      @nodes = Nodes::NodeSet.new
      @cache = {}
      @pxe = {}
      @cmd_ext = {}
    end

    # Load the common configuration file
    #
    # Arguments
    # * nothing
    # Output
    # * return true in case of success, false otherwise
    def load
      configfile = self.class.file
      begin
        begin
          config = YAML.load_file(configfile)
        rescue Errno::ENOENT
          raise ArgumentError.new("File not found '#{configfile}'")
        rescue Exception
          raise ArgumentError.new("Invalid YAML file '#{configfile}'")
        end

        static = {}
        cp = Parser.new(config)

        cp.parse('database',true) do
          @db_kind = cp.value('kind',String,nil,'mysql')
          @deploy_db_host = cp.value('host',String)
          @deploy_db_name = cp.value('name',String)
          @deploy_db_login = cp.value('login',String)
          @deploy_db_passwd = cp.value('passwd',String)
        end

        cp.parse('rights') do
          @rights_kind = cp.value('kind',String,'db',['db','dummy'])
          @almighty_env_users = cp.value(
            'almighty_users', String, 'root'
          ).split(",").collect! { |v| v.strip }
          @purge_deployment_timer = cp.value(
            'purge_deployment_timer', Fixnum, 900
          )
        end

        cp.parse('network',false) do
          cp.parse('vlan') do
            @vlan_hostname_suffix = cp.value('hostname_suffix',String,'')
            @set_vlan_cmd = cp.value('set_cmd',String,'',{
              :type => 'file', :command => true,
              :readable => true, :executable => true
            })
            @set_vlan_cmd = nil if @set_vlan_cmd.empty?
          end

          cp.parse('ports') do
            static[:port] = cp.value(
              'kadeploy_server',Fixnum,KADEPLOY_PORT
            )
            @ssh_port = cp.value('ssh',Fixnum,22)
            @test_deploy_env_port = cp.value(
              'test_deploy_env',Fixnum,KADEPLOY_PORT
            )
          end

          @kadeploy_tcp_buffer_size = cp.value(
            'tcp_buffer_size',Fixnum,8192
          )
          static[:host] = cp.value('server_hostname',String,Socket.gethostname)
        end

        cp.parse('security') do |info|
          static[:secure] = cp.value('secure_server',
            [TrueClass,FalseClass],true)

          static[:local] = cp.value('local_only',
            [TrueClass,FalseClass],false)

          cp.parse('private_key',false) do |inf|
            next if inf[:empty]
            file = cp.value('file',String,'',
              { :type => 'file', :readable => true, :prefix => Config.dir()})
            kind = cp.value('algorithm',String,nil,['RSA','DSA','EC'])
            next if file.empty?
            begin
              case kind
              when 'RSA'
                static[:private_key] = OpenSSL::PKey::RSA.new(File.read(file))
              when 'DSA'
                static[:private_key] = OpenSSL::PKey::DSA.new(File.read(file))
              when 'EC'
                static[:private_key] = OpenSSL::PKey::EC.new(File.read(file))
              else
                raise
              end
            rescue Exception => e
              raise ArgumentError.new(Parser.errmsg(inf[:path],"Unable to load #{kind} private key: #{e.message}"))
            end
          end
          cert = cp.value('certificate',String,'',
            { :type => 'file', :readable => true, :prefix => Config.dir()})
          if cert and !cert.empty?
            begin
              static[:cert] = OpenSSL::X509::Certificate.new(File.read(cert))
            rescue Exception => e
              raise ArgumentError.new(Parser.errmsg(info[:path],"Unable to load x509 cert file: #{e.message}"))
            end
          end

          if static[:cert]
            unless static[:private_key]
              raise ArgumentError.new(Parser.errmsg(info[:path],"You have to specify the private key associated with the x509 certificate"))
            end
            unless static[:cert].check_private_key(static[:private_key])
              raise ArgumentError.new(Parser.errmsg(info[:path],"The private key does not match with the x509 certificate"))
            end
          end

          @secure_client = cp.value('force_secure_client',
            [TrueClass,FalseClass],false)
        end

        cp.parse('authentication') do |nfo|
          # 192.168.0.42
          # 192.168.0.0/24
          # domain.tld
          # /^.*\.domain.tld$/
          parse_hostname = Proc.new do |hostname,path|
            addr = nil
            begin
              # Check if IP address
              addr = IPAddr.new(hostname)
            rescue ArgumentError
              # Check if Regexp
              if /\A\/(.*)\/\Z/ =~ hostname
                begin
                  addr = Regexp.new(Regexp.last_match(1))
                rescue
                  raise ArgumentError.new(Parser.errmsg(path,"Invalid regexp #{hostname}"))
                end
              end
            end
            # Resolv hostname
            if addr.nil?
              begin
                addr = IPAddr.new(Resolv.getaddress(hostname))
              rescue Resolv::ResolvError
                raise ArgumentError.new(Parser.errmsg(path,"Cannot resolv hostname #{hostname}"))
              rescue Exception => e
                raise ArgumentError.new(Parser.errmsg(path,"Invalid hostname #{hostname.inspect} (#{e.message})"))
              end
            end
            addr
          end

          cp.parse('global',false) do |info|
            static[:auth_headers_prefix] = cp.value('headers_prefix',String,'X-Kadeploy-')
          end

          cp.parse('acl',false) do |inf|
            next if inf[:empty]
            static[:auth] = {} unless static[:auth]
            static[:auth][:acl] = ACLAuthentication.new()
            cp.parse('whitelist',true,Array) do |info|
              next if info[:empty]
              static[:auth][:acl].whitelist << parse_hostname.call(info[:val][info[:iter]],info[:path])
            end
          end

          cp.parse('certificate',false) do |inf|
            next if inf[:empty]
            public_key = nil
            cp.parse('ca_public_key',false) do |info|
              next if info[:empty]
              file = cp.value('file',String,'',
                { :type => 'file', :readable => true, :prefix => Config.dir()})
              next if file.empty?
              kind = cp.value('algorithm',String,nil,['RSA','DSA','EC'])
              begin
                case kind
                when 'RSA'
                  public_key = OpenSSL::PKey::RSA.new(File.read(file))
                when 'DSA'
                  public_key = OpenSSL::PKey::DSA.new(File.read(file))
                when 'EC'
                  public_key = OpenSSL::PKey::EC.new(File.read(file))
                else
                  raise
                end
              rescue Exception => e
                raise ArgumentError.new(Parser.errmsg(nfo[:path],"Unable to load #{kind} public key: #{e.message}"))
              end
            end

            unless public_key
              cert = cp.value('ca_cert',String,'',
                { :type => 'file', :readable => true, :prefix => Config.dir()})
              if cert.empty?
                raise ArgumentError.new(Parser.errmsg(nfo[:path],"At least a certificate or a public key have to be specified"))
              else
                begin
                  cert = OpenSSL::X509::Certificate.new(File.read(cert))
                  public_key = cert.public_key
                rescue Exception => e
                  raise ArgumentError.new(Parser.errmsg(nfo[:path],"Unable to load x509 cert file: #{e.message}"))
                end
              end
            end

            static[:auth] = {} unless static[:auth]
            static[:auth][:cert] = CertificateAuthentication.new(public_key)
            if static[:local]
              static[:auth][:cert].whitelist << parse_hostname.call('localhost',inf[:path])
            else
              cp.parse('whitelist',false,Array) do |info|
                next if info[:empty]
                static[:auth][:cert].whitelist << parse_hostname.call(info[:val][info[:iter]],info[:path])
              end
            end
          end

          cp.parse('http_basic',false) do |inf|
            next if inf[:empty]
            static[:auth] = {} unless static[:auth]
            dbfile = cp.value('dbfile',String,nil,
              { :type => 'file', :readable => true, :prefix => Config.dir()})
            begin
              dbfile = WEBrick::HTTPAuth::Htpasswd.new(dbfile)
            rescue Exception => e
              raise ArgumentError.new(Parser.errmsg(inf[:path],"Unable to load htpasswd file: #{e.message}"))
            end
            static[:auth][:http_basic] = HTTPBasicAuthentication.new(dbfile,
              cp.value('realm',String,"http#{'s' if static[:secure]}://#{static[:host]}:#{static[:port]}"))
            if static[:local]
              static[:auth][:http_basic].whitelist << parse_hostname.call('localhost',inf[:path])
            else
              cp.parse('whitelist',false,Array) do |info|
                next if info[:empty]
                static[:auth][:http_basic].whitelist << parse_hostname.call(info[:val][info[:iter]],info[:path])
              end
            end
          end

          cp.parse('ident',false,Hash,false) do |info_ident|
            next unless info_ident[:provided]
            static[:auth] = {} unless static[:auth]
            static[:auth][:ident] = IdentAuthentication.new
            if static[:local]
              static[:auth][:ident].whitelist << parse_hostname.call('localhost',info_ident[:path])
            else
              cp.parse('whitelist',true,Array) do |info_white|
                next if info_white[:empty]
                static[:auth][:ident].whitelist << parse_hostname.call(info_white[:val][info_white[:iter]],info_white[:path])
              end
            end
          end

          if !static[:auth] or static[:auth].empty?
            raise ArgumentError.new(Parser.errmsg(nfo[:path],"You must set at least one authentication method"))
          end
        end

        static[:ssh_private_key] = cp.value('ssh_private_key',String, File.join($kadeploy_confdir,'keys','id_deploy'),
            { :type => 'file', :readable => true, :prefix => Config.dir()})

        cp.parse('logs') do
          static[:logfile] = cp.value(
            'logfile',String,'',
            { :type => 'file', :writable => true, :create => true }
          )
          static[:logfile] = nil if static[:logfile].empty?
          @log_to_db = cp.value('database',[TrueClass,FalseClass],true)
          @dbg_to_file = cp.value(
            'debugfile',String,'',
            { :type => 'file', :writable => true, :create => true }
          )
          @dbg_to_file = nil if @dbg_to_file.empty?
        end

        cp.parse('verbosity') do
          @dbg_to_file_level = cp.value('logs',Fixnum,3,(0..4))
          @verbose_level = cp.value('clients',Fixnum,3,(0..4))
        end

        cp.parse('cache',true) do |inf_cache|
          static[:caches] = {} unless static[:caches]
          static[:caches][:global] = {}
          static[:caches][:global][:directory] = cp.value('directory',String,'/tmp',
            {
              :type => 'dir',
              :readable => true,
              :writable => true,
              :create => true,
              :mode => 0700
            }
          )
          static[:caches][:global][:size] = cp.value('size', Fixnum)*1024*1024
        end

        cp.parse('windows') do
          cp.parse('reboot') do
            static[:reboot_window] = cp.value('size',Fixnum,50)
            static[:reboot_window_sleep_time] = cp.value('sleep_time',Fixnum,10)
          end

          cp.parse('check') do
            static[:nodes_check_window] = cp.value('size',Fixnum,50)
          end
        end

        cp.parse('environments') do
          cp.parse('deployment') do
            @environment_extraction_dir = cp.value(
              'extraction_dir',String,'/mnt/dest',Pathname
            )
            @rambin_path = cp.value('rambin_dir',String,'/rambin',Pathname)
            @tarball_dest_dir = cp.value(
              'tarball_dir',String,'/tmp',Pathname
            )
          end
          @max_preinstall_size =
            cp.value('max_preinstall_size',Fixnum,20) *1024 * 1024
          @max_postinstall_size =
            cp.value('max_postinstall_size',Fixnum,20) * 1024 * 1024
        end

        cp.parse('pxe',true) do
          chain = nil
          cp.parse('dhcp',true) do |info|
            chain = pxemethod(:dhcp,info,cp,static)
          end

          cp.parse('localboot') do |info|
            pxemethod(:local,info,cp,static,chain)
          end
          @pxe[:local] = chain unless @pxe[:local]

          cp.parse('networkboot') do |info|
            pxemethod(:network,info,cp,static,chain)
          end
          @pxe[:network] = chain unless @pxe[:network]
        end

        cp.parse('hooks') do
          @end_of_deploy_hook = cp.value('end_of_deployment',String,'',{
            :type => 'file', :command => true,
            :readable => true, :executable => true
          })
          @end_of_deploy_hook = nil if @end_of_deploy_hook.empty?
          @end_of_reboot_hook = cp.value('end_of_reboot',String,'',{
            :type => 'file', :command => true,
            :readable => true, :executable => true
          })
          @end_of_reboot_hook = nil if @end_of_reboot_hook.empty?
          @end_of_power_hook = cp.value('end_of_power',String,'',{
            :type => 'file', :command => true,
            :readable => true, :executable => true
          })
          @end_of_power_hook = nil if @end_of_power_hook.empty?
        end

        @autoclean_threshold = cp.value('autoclean_threshold',Fixnum,60*6).abs * 60 # 6h by default

        cp.parse('external') do
           @cmd_ext[:default_connector] = cp.value('default_connector',String,'ssh -A -l root -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=publickey -o BatchMode=yes')
          cp.parse('taktuk') do
            @taktuk_connector = cp.value('connector',String,'DEFAULT_CONNECTOR')
            @taktuk_connector.gsub!('DEFAULT_CONNECTOR',@cmd_ext[:default_connector])

            @taktuk_tree_arity = cp.value('tree_arity',Fixnum,0)
            @taktuk_auto_propagate = cp.value(
              'auto_propagate',[TrueClass,FalseClass],true
            )
            @taktuk_outputs_size = cp.value('outputs_size',Fixnum,20000)
          end

          cp.parse('bittorrent') do |info|
            unless info[:empty]
              @bt_tracker_ip = cp.value(
                'tracker_ip',String,nil,/\A\d{1,3}.\d{1,3}.\d{1,3}.\d{1,3}\Z/
              )
              @bt_download_timeout = cp.value('download_timeout',Fixnum)
            end
          end

          cp.parse('kastafior') do
            @kastafior = cp.value('binary',String,'kastafior')
          end

          cp.parse('kascade') do
            @kascade = cp.value('binary',String,'kascade')
            @kascade_options = cp.value('args',String,'')
          end

          @mkfs_options = Hash.new
          cp.parse('mkfs',false,Array) do |info|
            unless info[:empty]
              @mkfs_options[cp.value('fstype',String)] =
                cp.value('args',String)
            end
          end

          @tar_options = cp.value('tar',String,'')
        end

      rescue ArgumentError => ae
        $stderr.puts ''
        $stderr.puts "Error(#{configfile}) #{ae.message}"
        return false
      end

      cp.unused().each do |path|
        $stderr.puts "Warning(#{configfile}) Unused field '#{path}'"
      end

      return static
    end

    # Parse pxe part to build NetBoot object
    def pxemethod (name,info,cp,static,chain = nil)
      unless info[:empty]
        args = {}
        args[:kind] = cp.value('method',String,'PXElinux',
          ['PXElinux','GPXElinux','IPXE','GrubPXE']
        )
        args[:repository_dir] = cp.value('repository',String,nil,Dir)

        if name == :dhcp
          args[:binary] = 'DHCP_PXEBIN'
        else
          args[:binary] = cp.value('binary',String,nil,
            {:type => 'file', :prefix => args[:repository_dir], :const => true}
          )
        end

        cp.parse('export') do
          args[:export_kind] = cp.value('kind',String,'tftp',['http','ftp','tftp']).to_sym
          args[:export_server] = cp.value('server',String,'LOCAL_IP')
        end

        if name == :dhcp
            cp.parse('userfiles',true) do |info_userfiles|
              args[:custom_dir] = cp.value('directory',String,nil,
                {:type => 'dir', :prefix => args[:repository_dir]}
              )
              static[:caches] = {} unless static[:caches]
              static[:caches][:netboot] = {}
              static[:caches][:netboot][:directory] = File.join(args[:repository_dir],args[:custom_dir])
              static[:caches][:netboot][:size] = cp.value('max_size',Fixnum)*1024*1024
            end
        else
          args[:custom_dir] = 'PXE_CUSTOM'
        end

        cp.parse('profiles') do
          #TODO : check profile config for example : pxelinuix => pxelinux.cfg,ip_hex another=> another
          args[:profiles_dir] = cp.value('directory',String,'pxelinux.cfg')
          if args[:profiles_dir].empty?
            args[:profiles_dir] = args[:repository_dir]
          elsif !Pathname.new(args[:profiles_dir]).absolute?
            args[:profiles_dir] = File.join(args[:repository_dir],args[:profiles_dir])
          end
          if !File.exist?(args[:profiles_dir]) or !File.directory?(args[:profiles_dir])
            raise ArgumentError.new(Parser.errmsg(info[:path],"The directory '#{args[:profiles_dir]}' does not exist"))
          end
          args[:profiles_kind] = cp.value('filename',String,'ip_hex',
            ['ip','ip_hex','hostname','hostname_short']
          )
        end

        begin
          @pxe[name] = NetBoot.Factory(args[:kind], args[:binary], args[:export_kind], args[:export_server],
                          args[:repository_dir], args[:custom_dir], args[:profiles_dir], args[:profiles_kind], chain)
        rescue NetBoot::Exception => nbe
          raise ArgumentError.new(Parser.errmsg(info[:path],nbe.message))
        end
      end
    end
  end

  class ClustersConfig < Hash
    include ConfigFile

    def self.file()
      file = File.join($kadeploy_confdir, "clusters.conf")
      unless File.readable?(file)
        file = File.join($kadeploy_confdir, "clusters.yml")
        $stderr.puts "Warning using a deprecated configuration file, consider to rename it to 'clusters.conf'"
      end
      file
    end

    def load(commonconfig)
      configfile = self.class.file
      begin
        begin
          config = YAML.load_file(configfile)
        rescue Errno::ENOENT
          raise ArgumentError.new("File not found '#{configfile}'")
        rescue Exception
          raise ArgumentError.new("Invalid YAML file '#{configfile}'")
        end

        unless config.is_a?(Hash)
          raise ArgumentError.new("Invalid file format'#{configfile}'")
        end

        cp = Parser.new(config)

        cp.parse('clusters',true,Array) do
          clname = cp.value('name',String)


          clfile = cp.value(
            'conf_file',String,nil,{
              :type => 'file', :readable => true, :prefix => Config.dir()})

          conf = self[clname] = ClusterSpecificConfig.new(
            cp.value('prefix',String,''),commonconfig.cmd_ext)
          return false unless conf.load(clname,clfile)


          cp.parse('nodes',true,Array) do |info|
            name = cp.value('name',String)
            address = cp.value('address',String)

            if name =~ Nodes::REGEXP_NODELIST and address =~ Nodes::REGEXP_IPLIST
              hostnames = Nodes::NodeSet::nodes_list_expand(name)
              addresses = Nodes::NodeSet::nodes_list_expand(address)

              if (hostnames.to_a.length == addresses.to_a.length) then
                for i in (0 ... hostnames.to_a.length)
                  tmpname = hostnames[i]
                  commonconfig.nodes.push(Nodes::Node.new(
                    tmpname, addresses[i], clname
                  ))
                end
              else
                raise ArgumentError.new(Parser.errmsg(
                    info[:path],"Incoherent number of hostnames and IP addresses"
                  )
                )
              end
            else
              begin
                commonconfig.nodes.push(Nodes::Node.new(
                    name,
                    address,
                    clname
                ))
              rescue ArgumentError
                raise ArgumentError.new(Parser.errmsg(
                    info[:path],"Invalid address"
                  )
                )
              end
            end
          end
        end
      rescue ArgumentError => ae
        $stderr.puts ''
        $stderr.puts "Error(#{configfile}) #{ae.message}"
        return false
      end

      if commonconfig.nodes.empty? then
        puts "The nodes list is empty"
        return false
      else
        return true
      end
    end
  end

  class ClusterSpecificConfig
    include ConfigFile

    attr_reader :name
    attr_reader :deploy_kernel
    attr_reader :deploy_kernel_args
    attr_reader :deploy_initrd
    attr_reader :deploy_supported_fs
    attr_reader :kexec_repository
    attr_reader :block_device
    attr_reader :deploy_part
    attr_reader :prod_part
    attr_reader :tmp_part
    attr_reader :swap_part
    attr_reader :workflow_steps   #Array of MacroStep
    attr_reader :timeout_reboot_classical
    attr_reader :timeout_reboot_kexec
    attr_reader :cmd_reboot_soft
    attr_reader :cmd_reboot_hard
    attr_reader :cmd_reboot_very_hard
    attr_reader :cmd_console
    attr_reader :cmd_power_off_soft
    attr_reader :cmd_power_off_hard
    attr_reader :cmd_power_off_very_hard
    attr_reader :cmd_power_on_soft
    attr_reader :cmd_power_on_hard
    attr_reader :cmd_power_on_very_hard
    attr_reader :cmd_power_status
    attr_reader :cmd_sendenv
    attr_reader :decompress_environment
    attr_reader :group_of_nodes #Hashtable (key is a command name)
    attr_reader :partitioning_script
    attr_reader :bootloader_script
    attr_reader :sleep_time_before_ping
    attr_reader :prefix
    attr_reader :drivers
    attr_reader :pxe_header
    attr_reader :kernel_params
    attr_reader :nfsroot_kernel
    attr_reader :nfsroot_params
    attr_reader :admin_pre_install
    attr_reader :admin_post_install
    attr_reader :use_ip_to_deploy
    attr_reader :cmd_ext


    # Constructor of ClusterSpecificConfig
    #
    # Arguments
    # * nothing
    # Output
    # * nothing
    def initialize(prefix=nil,cmd_ext={})
      @prefix = prefix
      @workflow_steps = []
      @deploy_kernel_args = ""
      @deploy_supported_fs = []
      @kexec_repository = '/tmp/karepository'
      @group_of_nodes = {}
      @pxe_header = {}
      @use_ip_to_deploy = false

      @cmd_ext = cmd_ext.clone
    end

    def handle_cmd_priority(obj,conf_path,cp,cluster=null,limit=3)
      begin
        raise "This is not an array, please check the documentation." unless obj.is_a? Array
        raise "This version accepts only #{limit} commands." if obj.size > limit
        if (not obj.empty?) and (obj[0].is_a? Hash)
          output = []
          obj.each do |element|
              idx = @level_name.index(element['name'])
              raise "the '#{element['name']}' is not a valid name." if idx<0
              output[idx] = element['cmd']
              group = element['group']
              add_group_of_nodes("#{name}_reboot", group, cluster) unless group.nil? || cluster.nil?
          end
          obj = output
        end
        obj.each_index do |idx|
          cmd = obj[idx]
          if cmd
            raise "The provided command is not a string." unless cmd.is_a? String
            obj[idx] = cmd.gsub!('DEFAULT_CONNECTOR',@cmd_ext[:default_connector]) || obj[idx]
            cp.customcheck_file(cmd,nil,{
                  :type => 'file', :command => true,
                  :readable => true, :executable => true
                })
          end
        end
        obj
      rescue Exception => ex
        raise ArgumentError.new("error in #{conf_path}, #{ex}")
      end
    end


    def load(cluster, configfile)
      begin
        begin
          config = YAML.load_file(configfile)
        rescue Errno::ENOENT
          raise ArgumentError.new(
            "Cluster configuration file not found '#{configfile}'"
          )
        rescue Exception
          raise ArgumentError.new("Invalid YAML file '#{configfile}'")
        end

        unless config.is_a?(Hash)
          raise ArgumentError.new("Invalid file format'#{configfile}'")
        end

        #The method to add default automata is ugly, but it is readable.
        unless config['automata']
          add={'automata'=>{
                'macrosteps'=>{
                    'SetDeploymentEnv'=> [{
                        'timeout'=> 200,
                        'type'=>'Untrusted',
                        'retries'=> 2,
                    }],
                    'BroadcastEnv'=> [{
                        'timeout'=> 300,
                        'type'=>'Kascade',
                        'retries'=> 2,
                    }],
                    'BootNewEnv'=> [
                      {
                        'timeout'=> 150,
                        'type'=>'Classical',
                        'retries'=> 0,
                      },{
                        'timeout'=> 120,
                        'type'=>'HardReboot',
                        'retries'=> 1
                      }
                    ],
                  }
                }
              }
          config.merge!(add)
        end
        #end of ugly

        @name = cluster
        cp = Parser.new(config)

        cp.parse('partitioning',true) do
          @block_device = cp.value('block_device',String,nil,Pathname)

          @swap_part = cp.value('disable_swap',[TrueClass,FalseClass],false)? 'none':nil
          cp.parse('partitions',true) do
            @swap_part = cp.value('swap',Fixnum,nil).to_s unless @swap_part
            @prod_part = cp.value('prod',Fixnum,-1).to_s
            @deploy_part = cp.value('deploy',Fixnum).to_s
            @tmp_part = cp.value('tmp',Fixnum,-1).to_s
          end
          @partitioning_script = cp.value('script',String,nil,
            { :type => 'file', :readable => true, :prefix => Config.dir() })
        end

        cp.parse('boot',true) do
          @sleep_time_before_ping = cp.value('sleep_time_before_ping',Integer,20)
          @bootloader_script = cp.value('install_bootloader',String,nil,
            { :type => 'file', :readable => true, :prefix => Config.dir() })
          cp.parse('kernels',true) do
            cp.parse('user') do
              @kernel_params = cp.value('params',String,'')
            end

            cp.parse('deploy',true) do
              @deploy_kernel = cp.value('vmlinuz',String)
              @deploy_initrd = cp.value('initrd',String)
              @deploy_kernel_args = cp.value('params',String,'')
              @drivers = cp.value(
                'drivers',String,''
              ).split(',').collect{ |v| v.strip }
              @deploy_supported_fs = cp.value(
                'supported_fs',String,'ext2, ext3, ext4, vfat'
              ).split(',').collect{ |v| v.strip }
            end

            cp.parse('nfsroot') do
              @nfsroot_kernel = cp.value('vmlinuz',String,'')
              @nfsroot_params = cp.value('params',String,'')
            end
          end
        end

        cp.parse('remoteops',true) do  |remoteops_info|
          @level_name = cp.value('level_name',Array,['soft','hard','very_hard'])
          level_symbols = [:soft,:hard,:very_hard]

          [:power_off,:power_on,:reboot].each do |symb|
            @cmd_ext[symb]=handle_cmd_priority(cp.value(symb.to_s,Array,[]),remoteops_info[:path],cp,cluster)
            0.upto(level_symbols.length-1)  do |idx|
              self.instance_variable_set("@cmd_#{symb.to_s}_#{level_symbols[idx].to_s}".to_sym,@cmd_ext[symb][idx])
            end
          end

          @cmd_ext[:power_status] = handle_cmd_priority(cp.value('power_status',Array,[]),remoteops_info[:path],cp,nil,1)
          @cmd_power_status = @cmd_ext[:power_status][0]
          @cmd_ext[:console] = handle_cmd_priority(cp.value('console',Array,[]),remoteops_info[:path],cp,nil,1)
          @cmd_console = @cmd_ext[:console][0]

        end

        cp.parse('localops') do |info|
          cp.parse('broadcastenv') do
            unless info[:empty]
              @cmd_sendenv = cp.value('cmd',String,'',{
                :type => 'file', :command => true,
                :readable => true, :executable => true
              })
              @cmd_sendenv = nil if @cmd_sendenv.empty?
              @decompress_environment = !(cp.value('decompress',[TrueClass,FalseClass],true))
            end
          end
        end

        cp.parse('preinstall') do |info|
          cp.parse('files',false,Array) do
            unless info[:empty]
              @admin_pre_install = Array.new if info[:iter] == 0
              tmp = {}
              tmp['file'] = cp.value('file',String,nil,File)
              tmp['kind'] = cp.value('format',String,nil,['tgz','tbz2','txz'])
              tmp['script'] = cp.value('script',String,nil,Pathname)

              @admin_pre_install.push(tmp)
            end
          end
        end

        cp.parse('postinstall') do |info|
          cp.parse('files',false,Array) do
            unless info[:empty]
              @admin_post_install = Array.new if info[:iter] == 0
              tmp = {}
              tmp['file'] = cp.value('file',String,nil,File)
              tmp['kind'] = cp.value('format',String,nil,['tgz','tbz2','txz'])
              tmp['script'] = cp.value('script',String,nil,Pathname)

              @admin_post_install.push(tmp)
            end
          end
        end

        cp.parse('automata',true) do
          cp.parse('macrosteps',true) do
            microsteps = Microstep.instance_methods.select{ |name| name =~ /^ms_/ }
            microsteps.collect!{ |name| name.to_s.sub(/^ms_/,'') }

            treatcustom = Proc.new do |info,microname,ret|
              unless info[:empty]
                op = {
                  :name => "#{microname}-#{cp.value('name',String)}",
                  :action => cp.value('action',String,nil,['exec','send','run'])
                }
                case op[:action]
                when 'exec'
                  op[:command] = cp.value('command',String)
                  op[:timeout] = cp.value('timeout',Fixnum,0)
                  op[:retries] = cp.value('retries',Fixnum,0)
                  op[:scattering] = cp.value('scattering',String,:tree)
                when 'send'
                  op[:file] = cp.value('file',String,nil,
                    { :type => 'file', :readable => true, :prefix => Config.dir() })
                  op[:destination] = cp.value('destination',String)
                  op[:timeout] = cp.value('timeout',Fixnum,0)
                  op[:retries] = cp.value('retries',Fixnum,0)
                  op[:scattering] = cp.value('scattering',String,:tree)
                when 'run'
                  op[:file] = cp.value('file',String,nil,
                    { :type => 'file', :readable => true, :prefix => Config.dir() })
                  op[:params] = cp.value('params',String,'')
                  op[:timeout] = cp.value('timeout',Fixnum,0)
                  op[:retries] = cp.value('retries',Fixnum,0)
                  op[:scattering] = cp.value('scattering',String,:tree)
                end
                op[:action] = op[:action].to_sym
                ret << op
              end
            end

            treatmacro = Proc.new do |macroname|
              insts = ObjectSpace.each_object(Class).select { |klass|
                klass.ancestors.include?(Macrostep.const_get("Deploy#{macroname}"))
              } unless macroname.empty?
              insts.collect!{ |klass| klass.name.sub(/^Kadeploy::Macrostep::Deploy#{macroname}/,'') }
              macroinsts = []
              cp.parse(macroname,true,Array) do |info|
                unless info[:empty]
                  microconf = nil
                  cp.parse('microsteps',false,Array) do |info2|
                    unless info2[:empty]
                      microconf = {} unless microconf
                      microname = cp.value('name',String,nil,microsteps)

                      custom_sub = []
                      cp.parse('substitute',false,Array) do |info3|
                        treatcustom.call(info3,microname,custom_sub)
                      end
                      custom_sub = nil if custom_sub.empty?

                      custom_pre = []
                      cp.parse('pre-ops',false,Array) do |info3|
                        treatcustom.call(info3,microname,custom_pre)
                      end
                      custom_pre = nil if custom_pre.empty?

                      custom_post = []
                      cp.parse('post-ops',false,Array) do |info3|
                        treatcustom.call(info3,microname,custom_post)
                      end
                      custom_post = nil if custom_post.empty?

                      microconf[microname.to_sym] = {
                        :timeout => cp.value('timeout',Fixnum,0),
                        :raisable => cp.value(
                          'raisable',[TrueClass,FalseClass],true
                        ),
                        :breakpoint => cp.value(
                          'breakpoint',[TrueClass,FalseClass],false
                        ),
                        :retries => cp.value('retries',Fixnum,0),
                        :custom_sub => custom_sub,
                        :custom_pre => custom_pre,
                        :custom_post => custom_post,
                      }
                    end
                  end

                  macroinsts << [
                    macroname + cp.value('type',String,nil,insts),
                    cp.value('retries',Fixnum,0),
                    cp.value('timeout',Fixnum,0),
                    cp.value('raisable',[TrueClass,FalseClass],true),
                    cp.value('breakpoint',[TrueClass,FalseClass],false),
                    microconf,
                  ]
                end
              end
              @workflow_steps << MacroStep.new(macroname,macroinsts)
            end

            treatmacro.call('SetDeploymentEnv')
            treatmacro.call('BroadcastEnv')
            treatmacro.call('BootNewEnv')
          end
        end

        cp.parse('timeouts') do |info|
          code = cp.value('reboot',Object,120,
            { :type => 'code', :prefix => 'n=1;' }
          ).to_s
          begin
            code.to_i
          rescue
            raise ArgumentError.new(Parser.errmsg(
                info[:path],"Expression evaluation is not an integer"
              )
            )
          end

          n=1
          tmptime = eval(code)
          @workflow_steps[0].to_a.each do |macroinst|
            if [
              'SetDeploymentEnvUntrusted',
              'SetDeploymentEnvNfsroot',
            ].include?(macroinst[0]) and tmptime > macroinst[2]
            then
              raise ArgumentError.new(Parser.errmsg(
                  info[:path],"Global reboot timeout is greater than the timeout of the macrostep #{macroinst[0]}"
                )
              )
            end
          end
          @workflow_steps[2].to_a.each do |macroinst|
            if [
              'BootNewEnvClassical',
              'BootNewEnvHardReboot',
            ].include?(macroinst[0]) and tmptime > macroinst[2]
            then
              raise ArgumentError.new(Parser.errmsg(
                  info[:path],"Global reboot timeout is greater than the timeout of the macrostep #{macroinst[0]}"
                )
              )
            end
          end
          @timeout_reboot_classical = code

          code = cp.value('kexec',Object,60,
            { :type => 'code', :prefix => 'n=1;' }
          ).to_s
          begin
            code.to_i
          rescue
            raise ArgumentError.new(Parser.errmsg(
                info[:path],"Expression evaluation is not an integer"
              )
            )
          end

          n=1
          tmptime = eval(code)
          @workflow_steps[0].to_a.each do |macroinst|
            if macroinst[0] == 'SetDeploymentEnvKexec' and tmptime > macroinst[2]
            then
              raise ArgumentError.new(Parser.errmsg(
                  info[:path],"Global kexec timeout is greater than the timeout of the macrostep #{macroinst[0]}"
                )
              )
            end
          end
          @workflow_steps[2].to_a.each do |macroinst|
            if macroinst[0] == 'BootNewEnvKexec' and tmptime > macroinst[2]
            then
              raise ArgumentError.new(Parser.errmsg(
                  info[:path],"Global kexec timeout is greater than the timeout of the macrostep #{macroinst[0]}"
                )
              )
            end
          end
          @timeout_reboot_kexec = code
        end

        cp.parse('kexec') do
          @kexec_repository = cp.value(
            'repository',String,'/dev/shm/kexec_repository',Pathname
          )
        end

        cp.parse('pxe') do
          cp.parse('headers') do
            @pxe_header[:chain] = cp.value('dhcp',String,'')
            @pxe_header[:local] = cp.value('localboot',String,'')
            @pxe_header[:network] = cp.value('networkboot',String,'')
          end
        end

        cp.parse('hooks') do
          @use_ip_to_deploy = cp.value(
            'use_ip_to_deploy',[TrueClass,FalseClass],false
          )
        end

      rescue ArgumentError => ae
        $stderr.puts ''
        $stderr.puts "Error(#{configfile}) #{ae.message}"
        return false
      end

      cp.unused().each do |path|
        $stderr.puts "Warning(#{configfile}) Unused field '#{path}'"
      end

      #self.instance_variables.each{|v| self.class.send(:attr_accessor,v)}

      return true
    end

    # Specify that a command involves a group of node
    #
    # Arguments
    # * command: kind of command concerned
    # * file: file containing a node list (one group (nodes separated by a comma) by line)
    # * cluster: cluster concerned
    # Output
    # * return true if the group has been added correctly, false otherwise
    def add_group_of_nodes(command, file, cluster)
      if File.readable?(file) then
        @group_of_nodes[command] = Array.new
        IO.readlines(file).each do |line|
          @group_of_nodes[command].push(line.strip.split(","))
        end
      else
         raise ArgumentError.new(Parser.errmsg(info[:path],"Unable to read group of node '#{file}'"))
      end
    end
  end

  class CommandsConfig
    include ConfigFile

    def self.file()
      file = File.join($kadeploy_confdir, "command.conf")
      unless File.readable?(file)
        file = File.join($kadeploy_confdir, "cmd.yml")
        $stderr.puts "Warning using a deprecated configuration file, consider to rename it to 'command.conf'"
      end
      file
    end

    def load(common)
      configfile = self.class.file
      begin
        config = YAML.load_file(configfile)
      rescue Errno::ENOENT
        return true
      rescue Exception
        $stderr.puts "Invalid YAML file '#{configfile}'"
        return false
      end

      return true unless config

      unless config.is_a?(Hash)
        $stderr.puts "Invalid file format '#{configfile}'"
        return false
      end

      config.each_pair do |nodename,commands|
        node = common.nodes.get_node_by_host(nodename)

        if (node != nil) then
          commands.each_pair do |kind,val|
            if (node.cmd.instance_variable_defined?("@#{kind}")) then
              node.cmd.instance_variable_set("@#{kind}", val)
            else
              $stderr.puts "Unknown command kind: #{kind}"
              return false
            end
          end
        else
          $stderr.puts "The node #{nodename} does not exist"
          return false
        end
      end
    end
  end

  class MacroStep
    attr_accessor :name

    def initialize(name, instances)
      @name = name
      @instances = instances
    end

    def to_a
      return @instances
    end
  end

  def self.parse_custom_operation(cp,microname,opts={})
    ret = {
      :name => "#{microname}-#{cp.value('name',String)}",
      :action => cp.value('action',String,nil,['exec','send','run'])
    }
    fileopts = nil
    if opts[:check_files]
      fileopts = { :type => 'file', :readable => true, :prefix => Config.dir() }
    end

    case ret[:action]
    when 'exec'
      ret[:command] = cp.value('command',String)
      ret[:timeout] = cp.value('timeout',Fixnum,0)
      ret[:retries] = cp.value('retries',Fixnum,0)
      ret[:scattering] = cp.value('scattering',String,:tree)
    when 'send'
      ret[:file] = cp.value('file',String,nil,fileopts)
      ret[:destination] = cp.value('destination',String)
      ret[:timeout] = cp.value('timeout',Fixnum,0)
      ret[:retries] = cp.value('retries',Fixnum,0)
      ret[:scattering] = cp.value('scattering',String,:tree)
    when 'run'
      ret[:file] = cp.value('file',String,nil,fileopts)
      ret[:params] = cp.value('params',String,'')
      ret[:timeout] = cp.value('timeout',Fixnum,0)
      ret[:retries] = cp.value('retries',Fixnum,0)
      ret[:scattering] = cp.value('scattering',String,:tree)
    end
    ret[:action] = ret[:action].to_sym

    ret
  end

  def self.parse_custom_operations(cp,microname,opts={})
    ret = { :sub=>[], :pre=>[], :post=>[], :over=>nil }

    cp.parse('substitute',false,Array) do |info|
      unless info[:empty]
        val = parse_custom_operation(cp,microname,opts)
        val[:target] = :sub if opts[:set_target]
        ret[:sub] << val
      end
    end
    ret[:sub] = nil if ret[:sub].empty?

    cp.parse('pre-ops',false,Array) do |info|
      unless info[:empty]
        val = parse_custom_operation(cp,microname,opts)
        val[:target] = :'pre-ops' if opts[:set_target]
        ret[:pre] << val
      end
    end
    ret[:pre] = nil if ret[:pre].empty?

    cp.parse('post-ops',false,Array) do |info|
      unless info[:empty]
        val = parse_custom_operation(cp,microname,opts)
        val[:target] = :'post-ops' if opts[:set_target]
        ret[:post] << val
      end
    end
    ret[:post] = nil if ret[:post].empty?

    ret[:over] = cp.value('override',[TrueClass,FalseClass],false)

    ret
  end

  def self.parse_custom_macrostep(cp,macrobase,opts={})
    ret = []

    cp.parse(macrobase,true,Array) do |info|
      name = cp.value('name',String)
      raise ArgumentError.new("Unknown macrostep name '#{name}'") \
        unless check_macrostep_instance(name,:deploy)
      ret << [
        name,
        cp.value('retries',Fixnum,0),
        cp.value('timeout',Fixnum,0),
      ]
    end

    ret
  end

  def self.parse_custom_macrosteps(cp,opts={})
    ret = []

    parse_macro = Proc.new do |macrobase|
      ret << MacroStep.new(macrobase, parse_custom_macrostep(cp,macrobase,opts))
    end

    parse_macro.call('SetDeploymentEnv')
    parse_macro.call('BroadcastEnv')
    parse_macro.call('BootNewEnv')

    ret
  end

  def self.check_macrostep_interface(name,kind)
    kind = kind.to_s.capitalize
    klassbase = ::Kadeploy::Macrostep.const_get(kind)
    macrointerfaces = ObjectSpace.each_object(Class).select { |klass|
      klass.superclass == klassbase
    }
    macrointerfaces.collect!{ |klass| klass.name.split('::').last.gsub(/^#{kind}/,'') }

    return macrointerfaces.include?(name)
  end

  def self.check_macrostep_instance(name,kind)
    # Gathering a list of availables macrosteps
    klassbase = ::Kadeploy::Macrostep.const_get(kind.to_s.capitalize)
    macrosteps = ObjectSpace.each_object(Class).select { |klass|
      klass.ancestors.include?(klassbase)
    }

    # Do not consider rought step names as valid
    if kind == :deploy
      macrointerfaces = ObjectSpace.each_object(Class).select { |klass|
        klass.superclass == klassbase
      }
    else
      macrointerfaces = [klassbase]
    end
    macrointerfaces.each { |interface| macrosteps.delete(interface) }

    macrosteps.collect!{ |klass| klass.step_name }

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
end

end
