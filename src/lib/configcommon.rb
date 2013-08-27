require 'yaml'
require 'resolv'
require 'ipaddr'

require 'config'
require 'configparser'

module Kadeploy

module Configuration

  KADEPLOY_PORT = 25300

  class CommonConfig
    include ConfigFile

    def self.file()
      File.join($kadeploy_config_directory, "server_conf.yml")
    end

    attr_accessor :cache
    attr_accessor :verbose_level
    attr_accessor :pxe
    attr_accessor :auth
    attr_accessor :db_kind
    attr_accessor :deploy_db_host
    attr_accessor :deploy_db_name
    attr_accessor :deploy_db_login
    attr_accessor :deploy_db_passwd
    attr_accessor :rights_kind
    attr_accessor :nodes
    attr_accessor :taktuk_connector
    attr_accessor :taktuk_tree_arity
    attr_accessor :taktuk_outputs_size
    attr_accessor :taktuk_auto_propagate
    attr_accessor :tarball_dest_dir
    attr_accessor :kadeploy_server
    attr_accessor :kadeploy_server_port
    attr_accessor :kadeploy_tcp_buffer_size
    attr_accessor :max_preinstall_size
    attr_accessor :max_postinstall_size
    attr_accessor :kadeploy_disable_cache
    attr_accessor :ssh_port
    attr_accessor :test_deploy_env_port
    attr_accessor :environment_extraction_dir
    attr_accessor :log_to_file
    attr_accessor :log_to_syslog
    attr_accessor :log_to_db
    attr_accessor :dbg_to_file
    attr_accessor :dbg_to_file_level
    attr_accessor :reboot_window
    attr_accessor :reboot_window_sleep_time
    attr_accessor :nodes_check_window
    attr_accessor :purge_deployment_timer
    attr_accessor :rambin_path
    attr_accessor :mkfs_options
    attr_accessor :bt_tracker_ip
    attr_accessor :bt_download_timeout
    attr_accessor :almighty_env_users
    attr_accessor :version
    attr_accessor :async_end_of_deployment_hook
    attr_accessor :async_end_of_reboot_hook
    attr_accessor :async_end_of_power_hook
    attr_accessor :vlan_hostname_suffix
    attr_accessor :set_vlan_cmd
    attr_accessor :kastafior
    attr_accessor :secure_client
    attr_accessor :secure_server
    attr_accessor :cert
    attr_accessor :private_key

    # Constructor of CommonConfig
    #
    # Arguments
    # * nothing
    # Output
    # * nothing
    def initialize
      @nodes = Nodes::NodeSet.new
      @cache = {}
      @pxe = {}
      @auth = {}
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

        cp = Parser.new(config)

        cp.parse('database',true) do
          conf.db_kind = cp.value('kind',String,nil,'mysql')
          conf.deploy_db_host = cp.value('host',String)
          conf.deploy_db_name = cp.value('name',String)
          conf.deploy_db_login = cp.value('login',String)
          conf.deploy_db_passwd = cp.value('passwd',String)
        end

        cp.parse('rights') do
          conf.rights_kind = cp.value('kind',String,'db',['db','dummy'])
          conf.almighty_env_users = cp.value(
            'almighty_users', String, 'root'
          ).split(",").collect! { |v| v.strip }
          conf.purge_deployment_timer = cp.value(
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

            conf.auth[:cert] = CertificateAuthentication.new(public_key)
            cp.parse('whitelist',false,Array) do |info|
              next if info[:empty]
              conf.auth[:cert].whitelist << parse_hostname.call(info[:val][info[:iter]],info[:path])
            end
          end

          cp.parse('secret_key',false) do |inf|
            next if inf[:empty]
            conf.auth[:secret_key] = SecretKeyAuthentication.new(
              cp.value('key',String))
            cp.parse('whitelist',false,Array) do |info|
              next if info[:empty]
              conf.auth[:secret_key].whitelist << parse_hostname.call(info[:val][info[:iter]],info[:path])
            end
          end

          cp.parse('ident',false) do |inf|
            next if inf[:empty]
            conf.auth[:ident] = IdentAuthentication.new
            cp.parse('whitelist',true,Array) do |info|
              next if info[:empty]
              conf.auth[:ident].whitelist << parse_hostname.call(info[:val][info[:iter]],info[:path])
            end
          end
          if conf.auth.empty?
            raise ArgumentError.new(Parser.errmsg(nfo[:path],"You must set at least one authentication method"))
          end
        end

        cp.parse('security') do |info|
          conf.secure_server = cp.value('secure_server',
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
                conf.private_key = OpenSSL::PKey::RSA.new(File.read(file))
              when 'DSA'
                conf.private_key = OpenSSL::PKey::DSA.new(File.read(file))
              when 'EC'
                conf.private_key = OpenSSL::PKey::EC.new(File.read(file))
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
              conf.cert = OpenSSL::X509::Certificate.new(File.read(cert))
            rescue Exception => e
              raise ArgumentError.new(Parser.errmsg(info[:path],"Unable to load x509 cert file: #{e.message}"))
            end
          end

          if conf.cert
            unless conf.private_key
              raise ArgumentError.new(Parser.errmsg(info[:path],"You have to specify the private key associated with the x509 certificate"))
            end
            unless conf.cert.check_private_key(conf.private_key)
              raise ArgumentError.new(Parser.errmsg(info[:path],"The private key does not match with the x509 certificate"))
            end
          end

          conf.secure_client = cp.value('force_secure_client',
            [TrueClass,FalseClass],false)
        end

        cp.parse('logs') do
          conf.log_to_file = cp.value(
            'logfile',String,'',
            { :type => 'file', :writable => true, :create => true }
          )
          conf.log_to_file = nil if conf.log_to_file.empty?
          conf.log_to_db = cp.value('database',[TrueClass,FalseClass],true)
          conf.dbg_to_file = cp.value(
            'debugfile',String,'',
            { :type => 'file', :writable => true, :create => true }
          )
          conf.dbg_to_file = nil if conf.dbg_to_file.empty?
        end

        cp.parse('verbosity') do
          conf.dbg_to_file_level = cp.value('logs',Fixnum,3,(0..4))
          conf.verbose_level = cp.value('clients',Fixnum,3,(0..4))
        end

        cp.parse('cache',true) do
          conf.kadeploy_disable_cache = cp.value(
            'disabled',[TrueClass, FalseClass],false
          )
          unless conf.kadeploy_disable_cache
            directory = cp.value('directory',String,'/tmp',
              {
                :type => 'dir',
                :readable => true,
                :writable => true,
                :create => true,
                :mode => 0700
              }
            )
            size = cp.value('size', Fixnum)
            conf.cache[:global] = Cache.new(directory,size*1024*1024,
              CacheIndexPVHash,true)
          end
        end

        cp.parse('network',true) do
          cp.parse('vlan',true) do
            conf.vlan_hostname_suffix = cp.value('hostname_suffix',String,'')
            conf.set_vlan_cmd = cp.value('set_cmd',String,'')
          end

          cp.parse('ports') do
            conf.kadeploy_server_port = cp.value(
              'kadeploy_server',Fixnum,KADEPLOY_PORT
            )
            conf.ssh_port = cp.value('ssh',Fixnum,22)
            conf.test_deploy_env_port = cp.value(
              'test_deploy_env',Fixnum,KADEPLOY_PORT
            )
          end

          conf.kadeploy_tcp_buffer_size = cp.value(
            'tcp_buffer_size',Fixnum,8192
          )
          conf.kadeploy_server = cp.value('server_hostname',String)
        end

        cp.parse('windows') do
          cp.parse('reboot') do
            conf.reboot_window = cp.value('size',Fixnum,50)
            conf.reboot_window_sleep_time = cp.value('sleep_time',Fixnum,10)
          end

          cp.parse('check') do
            conf.nodes_check_window = cp.value('size',Fixnum,50)
          end
        end

        cp.parse('environments') do
          cp.parse('deployment') do
            conf.environment_extraction_dir = cp.value(
              'extraction_dir',String,'/mnt/dest',Pathname
            )
            conf.rambin_path = cp.value('rambin_dir',String,'/rambin',Pathname)
            conf.tarball_dest_dir = cp.value(
              'tarball_dir',String,'/tmp',Pathname
            )
          end
          conf.max_preinstall_size =
            cp.value('max_preinstall_size',Fixnum,20) *1024 * 1024
          conf.max_postinstall_size =
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
                  directory = File.join(repo,files)
                  size = cp.value('max_size',Fixnum)
                  conf.cache[:netboot] = Cache.new(directory,size*1024*1024,
                    CacheIndexPVHash,false)
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
                conf.pxe[name] = NetBoot.Factory(*args)
              rescue NetBoot::Exception => nbe
                raise ArgumentError.new(Parser.errmsg(info[:path],nbe.message))
              end
            end
          end

          cp.parse('dhcp',true) do |info|
            pxemethod.call(:dhcp,info)
          end

          chain = conf.pxe[:dhcp]
          cp.parse('localboot') do |info|
            pxemethod.call(:local,info)
          end
          conf.pxe[:local] = chain unless conf.pxe[:local]

          cp.parse('networkboot') do |info|
            pxemethod.call(:network,info)
          end
          conf.pxe[:network] = chain unless conf.pxe[:network]
        end

        cp.parse('hooks') do
          conf.async_end_of_deployment_hook = cp.value(
            'end_of_deployment',String,''
          )
          conf.async_end_of_reboot_hook = cp.value('end_of_reboot',String,'')
          conf.async_end_of_power_hook = cp.value('end_of_power',String,'')
        end

        cp.parse('external',true) do
          cp.parse('taktuk',true) do
            conf.taktuk_connector = cp.value('connector',String)
            conf.taktuk_tree_arity = cp.value('tree_arity',Fixnum,0)
            conf.taktuk_auto_propagate = cp.value(
              'auto_propagate',[TrueClass,FalseClass],true
            )
            conf.taktuk_outputs_size = cp.value('outputs_size',Fixnum,20000)
          end

          cp.parse('bittorrent') do |info|
            unless info[:empty]
              conf.bt_tracker_ip = cp.value(
                'tracker_ip',String,nil,/\A\d{1,3}.\d{1,3}.\d{1,3}.\d{1,3}\Z/
              )
              conf.bt_download_timeout = cp.value('download_timeout',Fixnum)
            end
          end

          cp.parse('kastafior') do
            conf.kastafior = cp.value('binary',String,'kastafior')
          end

          conf.mkfs_options = Hash.new
          cp.parse('mkfs',false,Array) do |info|
            unless info[:empty]
              conf.mkfs_options[cp.value('fstype',String)] =
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

      return true
    end
  end
end

end
