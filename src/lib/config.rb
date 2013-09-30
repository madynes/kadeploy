#Kadeploy libs
require 'environment'
require 'nodes'
require 'debug'
require 'error'
require 'configparser'
require 'macrostep'
require 'stepdeployenv'
require 'stepbroadcastenv'
require 'stepbootnewenv'
require 'microsteps'
require 'netboot'
require 'grabfile'
require 'authentication'

#Ruby libs
require 'optparse'
require 'ostruct'
require 'fileutils'
require 'resolv'
require 'ipaddr'
require 'yaml'

module Kadeploy

R_HOSTNAME = /\A[A-Za-z0-9\.\-\[\]\,]*\Z/
R_HTTP = /^http[s]?:\/\//

module Configuration
  USER = `id -nu`.chomp
  CONTACT_EMAIL = "kadeploy3-users@lists.gforge.inria.fr"
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
    VERSION_FILE = File.join($kadeploy_config_directory, "version")

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

        # Caches
        if caches
          @caches = caches
        else
          @caches = load_caches()
        end

        @static.freeze
        @caches.freeze if @caches

        raise KadeployError.new(APIError::BAD_CONFIGURATION,nil,
          "Problem in configuration") if not res
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
      ENV['KADEPLOY_CONFIG_DIR']||'/etc/kadeploy3'
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
      if !@static[:disable_cache] and @static[:caches][:global]
        ret[:global] = Cache.new(
          @static[:caches][:global][:directory],
          @static[:caches][:global][:size],
          CacheIndexPVHash,true
        )
      end

      if @static[:caches][:netboot]
        ret[:netboot] = Cache.new(
          @static[:caches][:netboot][:directory],
          @static[:caches][:netboot][:size],
          CacheIndexPVHash,false
        )
      end

      ret
    end
  end

  class CommonConfig
    include ConfigFile

    def self.file()
      File.join($kadeploy_config_directory, "server_conf.yml")
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
    attr_reader :bt_tracker_ip
    attr_reader :bt_download_timeout
    attr_reader :almighty_env_users
    attr_reader :version
    attr_reader :async_end_of_deployment_hook
    attr_reader :async_end_of_reboot_hook
    attr_reader :async_end_of_power_hook
    attr_reader :vlan_hostname_suffix
    attr_reader :set_vlan_cmd
    attr_reader :kastafior
    attr_reader :secure_client

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
              # TODO: Load from relative directory after the patch is applied
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
            cp.parse('whitelist',false,Array) do |info|
              next if info[:empty]
              static[:auth][:cert].whitelist << parse_hostname.call(info[:val][info[:iter]],info[:path])
            end
          end

          cp.parse('secret_key',false) do |inf|
            next if inf[:empty]
            static[:auth] = {} unless static[:auth]
            static[:auth][:secret_key] = SecretKeyAuthentication.new(
              cp.value('key',String))
            cp.parse('whitelist',false,Array) do |info|
              next if info[:empty]
              static[:auth][:secret_key].whitelist << parse_hostname.call(info[:val][info[:iter]],info[:path])
            end
          end

          cp.parse('ident',false) do |inf|
            next if inf[:empty]
            static[:auth] = {} unless static[:auth]
            static[:auth][:ident] = IdentAuthentication.new
            cp.parse('whitelist',true,Array) do |info|
              next if info[:empty]
              static[:auth][:ident].whitelist << parse_hostname.call(info[:val][info[:iter]],info[:path])
            end
          end
          if static[:auth].empty?
            raise ArgumentError.new(Parser.errmsg(nfo[:path],"You must set at least one authentication method"))
          end
        end

        cp.parse('security') do |info|
          static[:secure] = cp.value('secure_server',
            [TrueClass,FalseClass],true)

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

        cp.parse('cache',true) do
          static[:disable_cache] = cp.value(
            'disabled',[TrueClass, FalseClass],false
          )
          unless static[:disable_cache]
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
        end

        cp.parse('network',true) do
          cp.parse('vlan',true) do
            @vlan_hostname_suffix = cp.value('hostname_suffix',String,'')
            @set_vlan_cmd = cp.value('set_cmd',String,'')
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
          static[:host] = cp.value('server_hostname',String)
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
          pxemethod = Proc.new do |name,info|
            unless info[:empty]
              args = []
              args << cp.value('method',String,nil,
                ['PXElinux','GPXElinux','IPXE','GrubPXE']
              )
              repo = cp.value('repository',String,nil,Dir)

              if name == :dhcp
                args << 'DHCP_PXEBIN'
              else
                args << cp.value('binary',String,nil,
                  {:type => 'file', :prefix => repo}
                )
              end

              cp.parse('export',true) do
                args << cp.value('kind',String,nil,['http','ftp','tftp']).to_sym
                args << cp.value('server',String)
              end

              args << repo
              if name == :dhcp
                cp.parse('userfiles',true) do
                  files = cp.value('directory',String,nil,
                    {:type => 'dir', :prefix => repo}
                  )
                  args << files
                  static[:caches] = {} unless static[:caches]
                  static[:caches][:netboot] = {}
                  static[:caches][:netboot][:directory] = File.join(repo,files)
                  static[:caches][:netboot][:size] = cp.value('max_size',Fixnum)*1024*1024
                end
              else
                args << 'PXE_CUSTOM'
              end

              cp.parse('profiles',true) do
                profiles_dir = cp.value('directory',String,'')
                args << profiles_dir
                if profiles_dir.empty?
                  profiles_dir = repo
                elsif !Pathname.new(profiles_dir).absolute?
                  profiles_dir = File.join(repo,profiles_dir)
                end
                if !File.exist?(profiles_dir) or !File.directory?(profiles_dir)
                  raise ArgumentError.new(Parser.errmsg(info[:path],"The directory '#{profiles_dir}' does not exist"))
                end
                args << cp.value('filename',String,nil,
                  ['ip','ip_hex','hostname','hostname_short']
                )
              end
              args << chain

              begin
                @pxe[name] = NetBoot.Factory(*args)
              rescue NetBoot::Exception => nbe
                raise ArgumentError.new(Parser.errmsg(info[:path],nbe.message))
              end
            end
          end

          cp.parse('dhcp',true) do |info|
            pxemethod.call(:dhcp,info)
          end

          chain = @pxe[:dhcp]
          cp.parse('localboot') do |info|
            pxemethod.call(:local,info)
          end
          @pxe[:local] = chain unless @pxe[:local]

          cp.parse('networkboot') do |info|
            pxemethod.call(:network,info)
          end
          @pxe[:network] = chain unless @pxe[:network]
        end

        cp.parse('hooks') do
          @async_end_of_deployment_hook = cp.value(
            'end_of_deployment',String,''
          )
          @async_end_of_reboot_hook = cp.value('end_of_reboot',String,'')
          @async_end_of_power_hook = cp.value('end_of_power',String,'')
        end

        cp.parse('external',true) do
          cp.parse('taktuk',true) do
            @taktuk_connector = cp.value('connector',String)
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

          @mkfs_options = Hash.new
          cp.parse('mkfs',false,Array) do |info|
            unless info[:empty]
              @mkfs_options[cp.value('fstype',String)] =
                cp.value('args',String)
            end
          end
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
  end

  class ClustersConfig < Hash
    include ConfigFile

    def self.file()
      File.join($kadeploy_config_directory, "clusters.yml")
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
            cp.value('prefix',String,''))
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
    attr_reader :prefix
    attr_reader :drivers
    attr_reader :pxe_header
    attr_reader :kernel_params
    attr_reader :nfsroot_kernel
    attr_reader :nfsroot_params
    attr_reader :admin_pre_install
    attr_reader :admin_post_install
    attr_reader :use_ip_to_deploy

    # Constructor of ClusterSpecificConfig
    #
    # Arguments
    # * nothing
    # Output
    # * nothing
    def initialize(prefix=nil)
      @prefix = prefix
      @workflow_steps = []
      @deploy_kernel_args = ""
      @deploy_supported_fs = []
      @kexec_repository = '/tmp/karepository'
      @group_of_nodes = {}
      @pxe_header = {}
      @use_ip_to_deploy = false

      @cmd_reboot_soft = nil
      @cmd_reboot_hard = nil
      @cmd_reboot_very_hard = nil
      @cmd_console = nil
      @cmd_power_on_soft = nil
      @cmd_power_on_hard = nil
      @cmd_power_on_very_hard = nil
      @cmd_power_off_soft = nil
      @cmd_power_off_hard = nil
      @cmd_power_off_very_hard = nil
      @cmd_power_status = nil
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

        @name = cluster
        cp = Parser.new(config)

        cp.parse('partitioning',true) do
          @block_device = cp.value('block_device',String,nil,Pathname)
          cp.parse('partitions',true) do
            @swap_part = cp.value('swap',Fixnum,1).to_s
            @prod_part = cp.value('prod',Fixnum).to_s
            @deploy_part = cp.value('deploy',Fixnum).to_s
            @tmp_part = cp.value('tmp',Fixnum).to_s
          end
          @swap_part = 'none' if cp.value(
            'disable_swap',[TrueClass,FalseClass],false
          )
          @partitioning_script = cp.value('script',String,nil,
            { :type => 'file', :readable => true, :prefix => Config.dir() })
        end

        cp.parse('boot',true) do
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
                'supported_fs',String
              ).split(',').collect{ |v| v.strip }
            end

            cp.parse('nfsroot') do
              @nfsroot_kernel = cp.value('vmlinuz',String,'')
              @nfsroot_params = cp.value('params',String,'')
            end
          end
        end

        cp.parse('remoteops',true) do
          #ugly temporary hack
          group = nil
          addgroup = Proc.new do
            if group
              unless add_group_of_nodes("#{name}_reboot", group, cluster)
                raise ArgumentError.new(Parser.errmsg(
                    info[:path],"Unable to create group of node '#{group}' "
                  )
                )
              end
            end
          end

          cp.parse('reboot',false,Array) do |info|
=begin
            if info[:empty]
              raise ArgumentError.new(Parser.errmsg(
                  info[:path],'You need to specify at least one value'
                )
              )
            else
=end
            unless info[:empty]
              #ugly temporary hack
              name = cp.value('name',String,nil,['soft','hard','very_hard'])
              cmd = cp.value('cmd',String)
              group = cp.value('group',String,false)

              addgroup.call

              case name
                when 'soft'
                  @cmd_reboot_soft = cmd
                when 'hard'
                  @cmd_reboot_hard = cmd
                when 'very_hard'
                  @cmd_reboot_very_hard = cmd
              end
            end
          end

          cp.parse('power_on',false,Array) do |info|
            unless info[:empty]
              #ugly temporary hack
              name = cp.value('name',String,nil,['soft','hard','very_hard'])
              cmd = cp.value('cmd',String)
              group = cp.value('group',String,false)

              addgroup.call

              case name
                when 'soft'
                  @cmd_power_on_soft = cmd
                when 'hard'
                  @cmd_power_on_hard = cmd
                when 'very_hard'
                  @cmd_power_on_very_hard = cmd
              end
            end
          end

          cp.parse('power_off',false,Array) do |info|
            unless info[:empty]
              #ugly temporary hack
              name = cp.value('name',String,nil,['soft','hard','very_hard'])
              cmd = cp.value('cmd',String)
              group = cp.value('group',String,false)

              addgroup.call

              case name
                when 'soft'
                  @cmd_power_off_soft = cmd
                when 'hard'
                  @cmd_power_off_hard = cmd
                when 'very_hard'
                  @cmd_power_off_very_hard = cmd
              end
            end
          end

          cp.parse('power_status',false,Array) do |info|
            unless info[:empty]
              #ugly temporary hack
              if info[:iter] > 0
                raise ArgumentError.new(Parser.errmsg(
                    info[:path],"At the moment you can only set one single value "
                  )
                )
              end
              _ = cp.value('name',String)
              cmd = cp.value('cmd',String)
              @cmd_power_status = cmd
            end
          end

          cp.parse('console',true,Array) do |info|
            #ugly temporary hack
            if info[:iter] > 0
              raise ArgumentError.new(Parser.errmsg(
                  info[:path],"At the moment you can only set one single value "
                )
              )
            end
            _ = cp.value('name',String)
            cmd = cp.value('cmd',String)
            @cmd_console = cmd
          end
        end

        cp.parse('localops') do |info|
          cp.parse('broadcastenv') do
            unless info[:empty]
              @cmd_sendenv = cp.value('cmd',String)
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

        cp.parse('timeouts',true) do |info|
          code = cp.value('reboot',Object,nil,
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
          @workflow_steps[0].get_instances.each do |macroinst|
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
          @workflow_steps[2].get_instances.each do |macroinst|
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
          @workflow_steps[0].get_instances.each do |macroinst|
            if macroinst[0] == 'SetDeploymentEnvKexec' and tmptime > macroinst[2]
            then
              raise ArgumentError.new(Parser.errmsg(
                  info[:path],"Global kexec timeout is greater than the timeout of the macrostep #{macroinst[0]}"
                )
              )
            end
          end
          @workflow_steps[2].get_instances.each do |macroinst|
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
        IO.readlines(file).each { |line|
          @group_of_nodes[command].push(line.strip.split(","))
        }
        return true
      else
        return false
      end
    end
  end

  class CommandsConfig
    include ConfigFile

    def self.file()
      File.join($kadeploy_config_directory, "cmd.yml")
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
    @array_of_instances = nil #specify the instances by order of use, if the first one fails, we use the second, and so on
    @current = nil

    # Constructor of MacroStep
    #
    # Arguments
    # * name: name of the macro-step (SetDeploymentEnv, BroadcastEnv, BootNewEnv)
    # * array_of_instances: array of [instance_name, instance_max_retries, instance_timeout]
    # Output
    # * nothing 
    def initialize(name, array_of_instances)
      @name = name
      @array_of_instances = array_of_instances
      @current = 0
    end

    # Select the next instance implementation for a macro step
    #
    # Arguments
    # * nothing
    # Output
    # * return true if a next instance exists, false otherwise
    def use_next_instance
      if (@array_of_instances.length > (@current + 1)) then
        @current += 1
        return true
      else
        return false
      end
    end

    # Get the current instance implementation of a macro step
    #
    # Arguments
    # * nothing
    # Output
    # * return an array: [0] is the name of the instance, 
    #                    [1] is the number of retries available for the instance
    #                    [2] is the timeout for the instance
    def get_instance
      return @array_of_instances[@current]
    end

    def get_instances
      return @array_of_instances
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
