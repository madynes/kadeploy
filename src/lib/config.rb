# Kadeploy 3.1
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2012
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

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

R_HOSTNAME = /\A[A-Za-z0-9\.\-\[\]\,]*\Z/
R_HTTP = /^http[s]?:\/\//

module ConfigInformation
  CONFIGURATION_FOLDER = $kadeploy_config_directory
  VERSION_FILE = File.join(CONFIGURATION_FOLDER, "version")
  SERVER_CONFIGURATION_FILE = File.join(CONFIGURATION_FOLDER, "server_conf.yml")
  CLUSTERS_CONFIGURATION_FILE = File.join(CONFIGURATION_FOLDER, "clusters.yml")
  COMMANDS_FILE = File.join(CONFIGURATION_FOLDER, "cmd.yml")
  USER = `id -nu`.chomp
  CONTACT_EMAIL = "kadeploy3-users@lists.gforge.inria.fr"
  KADEPLOY_PORT = 25300

  class Config
    public

    attr_accessor :common
    attr_accessor :cluster_specific
    attr_accessor :exec_specific
    @opts = nil

    # Constructor of Config (used in KadeployServer)
    #
    # Arguments
    # * empty (opt): specify if an empty configuration must be generated
    # Output
    # * nothing if all is OK, otherwise raises an exception
    def initialize(empty = false)
      if not empty then
        if (sanity_check() == true) then
          @common = CommonConfig.new
          res = load_server_config_file
          @cluster_specific = Hash.new
          res = res && load_clusters_config_file
          res = res && load_commands
          res = res && load_version
          raise KadeployError.new(APIError::BAD_CONFIGURATION,nil,"Problem in configuration") if not res
        else
          raise KadeployError.new(APIError::BAD_CONFIGURATION,nil,"Unsane configuration")
        end
      end
    end

    # Check the config of the Kadeploy tools
    #
    # Arguments
    # * kind: tool (kadeploy, kaenv, karights, kastat, kareboot, kaconsole, kanodes)
    # Output
    # * calls the check_config method that correspond to the selected tool
    def check_client_config(kind, exec_specific_config, db, client)
      method = "check_#{kind.split("_")[0]}_config".to_sym
      return send(method, exec_specific_config, db, client)
    end

    def check_kareboot_config(exec_specific_config, db, client)
      #Nodes check
      exec_specific_config.node_array.each { |hostname|
        if not add_to_node_set(hostname, exec_specific_config) then
          Debug::distant_client_error("The node #{hostname} does not exist", client)
          return KarebootAsyncError::NODE_NOT_EXIST
        end
      }

      #VLAN
      if (exec_specific_config.vlan != nil) then
        if ((@common.vlan_hostname_suffix == "") || (@common.set_vlan_cmd == "")) then
          Debug::distant_client_error("No VLAN can be used on this site (some configuration is missing)", client)
          return KarebootAsyncError::VLAN_MGMT_DISABLED
        else
          dns = Resolv::DNS.new
          exec_specific_config.ip_in_vlan = Hash.new
          exec_specific_config.node_set.make_array_of_hostname.each { |hostname|
            hostname_a = hostname.split(".")
            hostname_in_vlan = "#{hostname_a[0]}#{@common.vlan_hostname_suffix}.#{hostname_a[1..-1].join(".")}".gsub("VLAN_ID", exec_specific_config.vlan)
            exec_specific_config.ip_in_vlan[hostname] = dns.getaddress(hostname_in_vlan).to_s
          }
          dns.close
          dns = nil
        end
      end

      #Rights check
      allowed_to_deploy = true
      #The rights must be checked for each cluster if the node_list contains nodes from several clusters
      exec_specific_config.node_set.group_by_cluster.each_pair { |cluster, set|
        if (allowed_to_deploy) then
          b = (exec_specific_config.block_device != "") ? exec_specific_config.block_device : @cluster_specific[cluster].block_device
          p = (exec_specific_config.deploy_part != "") ? exec_specific_config.deploy_part : @cluster_specific[cluster].deploy_part
          part = b + p
          allowed_to_deploy = CheckRights::CheckRightsFactory.create(@common.rights_kind,
                                                                     exec_specific_config.true_user,
                                                                     client, set, db, part).granted?
        end
      }
      if (not allowed_to_deploy) then
        puts "You do not have the right to deploy on all the nodes"
        Debug::distant_client_error("You do not have the right to deploy on all the nodes", client)
        return KarebootAsyncError::NO_RIGHT_TO_DEPLOY
      end

      if (exec_specific_config.reboot_kind == "env_recorded") then   
        private_envs = exec_specific_config.user.nil? \
          || exec_specific_config.user == exec_specific_config.true_user
        unless exec_specific_config.environment.load_from_db(
          db,
          exec_specific_config.env_arg,
          exec_specific_config.env_version,
          exec_specific_config.user || exec_specific_config.true_user,
          private_envs,
          exec_specific_config.user.nil?
        )
          client.print(
            "The environment #{exec_specific_config.env_arg} cannot be loaded. "\
            "Maybe the version number does not exist "\
            "or it belongs to another user"
          )
          return KarebootAsyncError::LOAD_ENV_FROM_DB_ERROR
        end
      end
      return KarebootAsyncError::NO_ERROR
    end

    def check_kastat_config(exec_specific_config, db, client)
      return 0
    end

    def check_kaconsole_config(exec_specific_config, db, client)
      node = @common.nodes_desc.get_node_by_host(exec_specific_config.node)
      if (node == nil) then
        Debug::distant_client_error("The node #{exec_specific_config.node} does not exist", client)
        return 1
      else
        exec_specific_config.node = node
      end
      return 0
    end

    def check_kanodes_config(exec_specific_config, db, client)
      return 0
    end

    def check_kapower_config(exec_specific_config, db, client)
      exec_specific_config.node_array.each { |hostname|
        if not add_to_node_set(hostname, exec_specific_config) then
          Debug::distant_client_error("The node #{hostname} does not exist", client)
          return 1
        end
      }

      #Rights check
      allowed_to_deploy = true
      #The rights must be checked for each cluster if the node_list contains nodes from several clusters
      exec_specific_config.node_set.group_by_cluster.each_pair { |cluster, set|
        if (allowed_to_deploy) then
          part = @cluster_specific[cluster].block_device + @cluster_specific[cluster].deploy_part
          allowed_to_deploy = CheckRights::CheckRightsFactory.create(@common.rights_kind,
                                                                     exec_specific_config.true_user,
                                                                     client, set, db, part).granted?
        end
      }
      if (not allowed_to_deploy) then
        Debug::distant_client_error("You do not have the right to deploy on all the nodes", client)
        return 2
      end

      return 0
    end

    private
    # Print an error message with the usage message
    #
    # Arguments
    # * msg: message to print
    # Output
    # * nothing
    def error(msg)
      Debug::local_client_error(msg, Proc.new { @opts.display })
    end

    # Print an error message with the usage message (class method required by the Kadeploy client)
    #
    # Arguments
    # * msg: message to print
    # Output
    # * nothing
    def Config.error(msg)
      Debug::local_client_error(msg, Proc.new { @opts.display })
    end

##################################
#         Generic part           #
##################################

    # Perform a test to check the consistancy of the installation
    #
    # Arguments
    # * nothing
    # Output
    # * return true if the installation is correct, false otherwise
    def sanity_check()
      if not File.readable?(SERVER_CONFIGURATION_FILE) then
        $stderr.puts "The #{SERVER_CONFIGURATION_FILE} file cannot be read"
        return false
      end
      if not File.readable?(CLUSTERS_CONFIGURATION_FILE) then
        $stderr.puts "The #{CLUSTERS_CONFIGURATION_FILE} file cannot be read"
        return false
      end
      if not File.readable?(VERSION_FILE) then
        $stderr.puts "The #{VERSION_FILE} file cannot be read"
        return false
      end
      return true
    end

    # Load the common configuration file
    #
    # Arguments
    # * nothing
    # Output
    # * return true in case of success, false otherwise
    def load_server_config_file
      configfile = SERVER_CONFIGURATION_FILE
      begin
        begin
          config = YAML.load_file(configfile)
        rescue Errno::ENOENT
          raise ArgumentError.new("File not found '#{configfile}'")
        rescue Exception
          raise ArgumentError.new("Invalid YAML file '#{configfile}'")
        end

        conf = @common
        cp = ConfigParser.new(config)

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
                  raise ArgumentError.new(ConfigParser.errmsg(path,"Invalid regexp #{hostname}"))
                end
              end
            end
            # Resolv hostname
            if addr.nil?
              begin
                addr = IPAddr.new(Resolv.getaddress(hostname))
              rescue Resolv::ResolvError
                raise ArgumentError.new(ConfigParser.errmsg(path,"Cannot resolv hostname #{hostname}"))
              rescue Exception => e
                raise ArgumentError.new(ConfigParser.errmsg(path,"Invalid hostname #{hostname.inspect} (#{e.message})"))
              end
            end
            addr
          end

          cp.parse('certificate',false) do |inf|
            next if inf[:empty]
            public_key = nil
            cp.parse('ca_public_key',false) do |info|
              next if info[:empty]
              # TODO: Load from relative directory after the patch is applied
              file = cp.value('file',String,'',{ :type => 'file', :readable => true})
              next if file.empty?
              kind = cp.value('algorithm',String,nil,['RSA','DSA','DH'])
              begin
                case kind
                when 'RSA'
                  public_key = OpenSSL::PKey::RSA.new(File.read(file))
                when 'DSA'
                  public_key = OpenSSL::PKey::DSA.new(File.read(file))
                when 'DH'
                  public_key = OpenSSL::PKey::DH.new(File.read(file))
                else
                  raise
                end
              rescue Exception => e
                raise ArgumentError.new(ConfigParser.errmsg(nfo[:path],"Unable to load #{kind} public key: #{e.message}"))
              end
            end

            unless public_key
              # TODO: Load from relative directory after the patch is applied
              cert = cp.value('ca_cert',String,'',{ :type => 'file', :readable => true})
              if cert.empty?
                raise ArgumentError.new(ConfigParser.errmsg(nfo[:path],"At least a certificate or a public key have to be specified"))
              else
                begin
                  cert = OpenSSL::X509::Certificate.new(File.read(cert))
                  public_key = cert.public_key
                rescue Exception => e
                  raise ArgumentError.new(ConfigParser.errmsg(nfo[:path],"Unable to load x509 cert file: #{e.message}"))
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
            raise ArgumentError.new(ConfigParser.errmsg(nfo[:path],"You must set at least one authentication method"))
          end
        end

        cp.parse('security') do |info|
          conf.secure_server = cp.value('secure_server',
            [TrueClass,FalseClass],true)

          cp.parse('private_key',false) do |inf|
            next if inf[:empty]
            file = cp.value('file',String,'',{ :type => 'file', :readable => true})
            kind = cp.value('algorithm',String,nil,['RSA','DSA','DH'])
            next if file.empty?
            begin
              case kind
              when 'RSA'
                conf.private_key = OpenSSL::PKey::RSA.new(File.read(file))
              when 'DSA'
                conf.private_key = OpenSSL::PKey::DSA.new(File.read(file))
              when 'DH'
                conf.private_key = OpenSSL::PKey::DH.new(File.read(file))
              else
                raise
              end
            rescue Exception => e
              raise ArgumentError.new(ConfigParser.errmsg(inf[:path],"Unable to load #{kind} private key: #{e.message}"))
            end
          end
          cert = cp.value('certificate',String,'',{ :type => 'file', :readable => true})
          if cert and !cert.empty?
            begin
              conf.cert = OpenSSL::X509::Certificate.new(File.read(cert))
            rescue Exception => e
              raise ArgumentError.new(ConfigParser.errmsg(info[:path],"Unable to load x509 cert file: #{e.message}"))
            end
          end

          if conf.cert
            unless conf.private_key
              raise ArgumentError.new(ConfigParser.errmsg(info[:path],"You have to specify the private key associated with the x509 certificate"))
            end
            unless conf.cert.check_private_key(conf.private_key)
              raise ArgumentError.new(ConfigParser.errmsg(info[:path],"The private key does not match with the x509 certificate"))
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
                  raise ArgumentError.new(ConfigParser.errmsg(info[:path],"The directory '#{profiles_dir}' does not exist"))
                end
                args << cp.value('filename',String,nil,
                  ['ip','ip_hex','hostname','hostname_short']
                )
              end
              args << chain

              begin
                conf.pxe[name] = NetBoot.Factory(*args)
              rescue NetBoot::Exception => nbe
                raise ArgumentError.new(ConfigParser.errmsg(info[:path],nbe.message))
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
          cp.parse('async') do
            conf.async_end_of_deployment_hook = cp.value(
              'end_of_deployment',String,''
            )
            conf.async_end_of_reboot_hook = cp.value('end_of_reboot',String,'')
            conf.async_end_of_power_hook = cp.value('end_of_power',String,'')
          end
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
        @cluster_specific[cluster].group_of_nodes[command] = Array.new
        IO.readlines(file).each { |line|
          @cluster_specific[cluster].group_of_nodes[command].push(line.strip.split(","))
        }
        return true
      else
        return false
      end
    end

    # Load the specific configuration files
    #
    # Arguments
    # * nothing
    # Output
    # * return true in case of success, false otherwise
    def load_clusters_config_file
      configfile = CLUSTERS_CONFIGURATION_FILE
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

        cp = ConfigParser.new(config)

        cp.parse('clusters',true,Array) do
          clname = cp.value('name',String)

          @cluster_specific[clname] = ClusterSpecificConfig.new
          conf = @cluster_specific[clname]
          conf.name = clname

          clfile = cp.value(
            'conf_file',String,nil,{ :type => 'file', :readable => true }
          )
          conf.prefix = cp.value('prefix',String,'')
          return false unless load_cluster_specific_config_file(clname,clfile)

          cp.parse('nodes',true,Array) do |info|
            name = cp.value('name',String)
            address = cp.value('address',String)

            if name =~ Nodes::REGEXP_NODELIST and address =~ Nodes::REGEXP_IPLIST
              hostnames = Nodes::NodeSet::nodes_list_expand(name)
              addresses = Nodes::NodeSet::nodes_list_expand(address)

              if (hostnames.to_a.length == addresses.to_a.length) then
                for i in (0 ... hostnames.to_a.length)
                  tmpname = hostnames[i]
                  @common.nodes_desc.push(Nodes::Node.new(
                    tmpname, addresses[i], clname, generate_commands(
                      tmpname, clname
                    )
                  ))
                end
              else
                raise ArgumentError.new(ConfigParser.errmsg(
                    info[:path],"Incoherent number of hostnames and IP addresses"
                  )
                )
              end
            else
              begin
                @common.nodes_desc.push(Nodes::Node.new(
                    name,
                    address,
                    clname,
                    generate_commands(name, clname)
                ))
              rescue ArgumentError
                raise ArgumentError.new(ConfigParser.errmsg(
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

      if @common.nodes_desc.empty? then
        puts "The nodes list is empty"
        return false
      else
        return true
      end
    end

    def load_cluster_specific_config_file(cluster, configfile)
      unless @cluster_specific[cluster]
        $stderr.puts "Internal error, cluster '' not declared"
        return false
      end

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

        conf = @cluster_specific[cluster]
        cp = ConfigParser.new(config)

        cp.parse('partitioning',true) do
          conf.block_device = cp.value('block_device',String,nil,Pathname)
          cp.parse('partitions',true) do
            conf.swap_part = cp.value('swap',Fixnum,1).to_s
            conf.prod_part = cp.value('prod',Fixnum).to_s
            conf.deploy_part = cp.value('deploy',Fixnum).to_s
            conf.tmp_part = cp.value('tmp',Fixnum).to_s
          end
          conf.swap_part = 'none' if cp.value(
            'disable_swap',[TrueClass,FalseClass],false
          )
          conf.partitioning_script = cp.value(
            'script',String,nil,{ :type => 'file', :readable => true }
          )
        end

        cp.parse('boot',true) do
          conf.bootloader_script = cp.value(
            'install_bootloader',String,nil,{ :type => 'file', :readable => true }
          )
          cp.parse('kernels',true) do
            cp.parse('user') do
              conf.kernel_params = cp.value('params',String,'')
            end

            cp.parse('deploy',true) do
              conf.deploy_kernel = cp.value('vmlinuz',String)
              conf.deploy_initrd = cp.value('initrd',String)
              conf.deploy_kernel_args = cp.value('params',String,'')
              conf.drivers = cp.value(
                'drivers',String,''
              ).split(',').collect{ |v| v.strip }
              conf.deploy_supported_fs = cp.value(
                'supported_fs',String
              ).split(',').collect{ |v| v.strip }
            end

            cp.parse('nfsroot') do
              conf.nfsroot_kernel = cp.value('vmlinuz',String,'')
              conf.nfsroot_params = cp.value('params',String,'')
            end
          end
        end

        cp.parse('remoteops',true) do
          #ugly temporary hack
          group = nil
          addgroup = Proc.new do
            if group
              unless add_group_of_nodes("#{name}_reboot", group, cluster)
                raise ArgumentError.new(ConfigParser.errmsg(
                    info[:path],"Unable to create group of node '#{group}' "
                  )
                )
              end
            end
          end

          cp.parse('reboot',false,Array) do |info|
=begin
            if info[:empty]
              raise ArgumentError.new(ConfigParser.errmsg(
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
                  conf.cmd_soft_reboot = cmd
                when 'hard'
                  conf.cmd_hard_reboot = cmd
                when 'very_hard'
                  conf.cmd_very_hard_reboot = cmd
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
                  conf.cmd_soft_power_on = cmd
                when 'hard'
                  conf.cmd_hard_power_on = cmd
                when 'very_hard'
                  conf.cmd_very_hard_power_on = cmd
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
                  conf.cmd_soft_power_off = cmd
                when 'hard'
                  conf.cmd_hard_power_off = cmd
                when 'very_hard'
                  conf.cmd_very_hard_power_off = cmd
              end
            end
          end

          cp.parse('power_status',false,Array) do |info|
            unless info[:empty]
              #ugly temporary hack
              if info[:iter] > 0
                raise ArgumentError.new(ConfigParser.errmsg(
                    info[:path],"At the moment you can only set one single value "
                  )
                )
              end
              _ = cp.value('name',String)
              cmd = cp.value('cmd',String)
              conf.cmd_power_status = cmd
            end
          end

          cp.parse('console',true,Array) do |info|
            #ugly temporary hack
            if info[:iter] > 0
              raise ArgumentError.new(ConfigParser.errmsg(
                  info[:path],"At the moment you can only set one single value "
                )
              )
            end
            _ = cp.value('name',String)
            cmd = cp.value('cmd',String)
            conf.cmd_console = cmd
          end
        end

        cp.parse('preinstall') do |info|
          cp.parse('files',false,Array) do
            unless info[:empty]
              conf.admin_pre_install = Array.new if info[:iter] == 0
              tmp = {}
              tmp['file'] = cp.value('file',String,nil,File)
              tmp['kind'] = cp.value('format',String,nil,['tgz','tbz2','txz'])
              tmp['script'] = cp.value('script',String,nil,Pathname)

              conf.admin_pre_install.push(tmp)
            end
          end
        end

        cp.parse('postinstall') do |info|
          cp.parse('files',false,Array) do
            unless info[:empty]
              conf.admin_post_install = Array.new if info[:iter] == 0
              tmp = {}
              tmp['file'] = cp.value('file',String,nil,File)
              tmp['kind'] = cp.value('format',String,nil,['tgz','tbz2','txz'])
              tmp['script'] = cp.value('script',String,nil,Pathname)

              conf.admin_post_install.push(tmp)
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
                  op[:file] = cp.value(
                    'file',String,nil,{ :type => 'file', :readable => true }
                  )
                  op[:destination] = cp.value('destination',String)
                  op[:timeout] = cp.value('timeout',Fixnum,0)
                  op[:retries] = cp.value('retries',Fixnum,0)
                  op[:scattering] = cp.value('scattering',String,:tree)
                when 'run'
                  op[:file] = cp.value(
                    'file',String,nil,{ :type => 'file', :readable => true }
                  )
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
                klass.ancestors.include?(Module.const_get(macroname))
              } unless macroname.empty?
              insts.collect!{ |klass| klass.name.sub(/^#{macroname}/,'') }
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
              conf.workflow_steps << MacroStep.new(macroname,macroinsts)
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
            raise ArgumentError.new(ConfigParser.errmsg(
                info[:path],"Expression evaluation is not an integer"
              )
            )
          end

          n=1
          tmptime = eval(code)
          conf.workflow_steps[0].get_instances.each do |macroinst|
            if [
              'SetDeploymentEnvUntrusted',
              'SetDeploymentEnvNfsroot',
            ].include?(macroinst[0]) and tmptime > macroinst[2]
            then
              raise ArgumentError.new(ConfigParser.errmsg(
                  info[:path],"Global reboot timeout is greater than the timeout of the macrostep #{macroinst[0]}"
                )
              )
            end
          end
          conf.workflow_steps[2].get_instances.each do |macroinst|
            if [
              'BootNewEnvClassical',
              'BootNewEnvHardReboot',
            ].include?(macroinst[0]) and tmptime > macroinst[2]
            then
              raise ArgumentError.new(ConfigParser.errmsg(
                  info[:path],"Global reboot timeout is greater than the timeout of the macrostep #{macroinst[0]}"
                )
              )
            end
          end
          conf.timeout_reboot_classical = code

          code = cp.value('kexec',Object,60,
            { :type => 'code', :prefix => 'n=1;' }
          ).to_s
          begin
            code.to_i
          rescue
            raise ArgumentError.new(ConfigParser.errmsg(
                info[:path],"Expression evaluation is not an integer"
              )
            )
          end

          n=1
          tmptime = eval(code)
          conf.workflow_steps[0].get_instances.each do |macroinst|
            if macroinst[0] == 'SetDeploymentEnvKexec' and tmptime > macroinst[2]
            then
              raise ArgumentError.new(ConfigParser.errmsg(
                  info[:path],"Global kexec timeout is greater than the timeout of the macrostep #{macroinst[0]}"
                )
              )
            end
          end
          conf.workflow_steps[2].get_instances.each do |macroinst|
            if macroinst[0] == 'BootNewEnvKexec' and tmptime > macroinst[2]
            then
              raise ArgumentError.new(ConfigParser.errmsg(
                  info[:path],"Global kexec timeout is greater than the timeout of the macrostep #{macroinst[0]}"
                )
              )
            end
          end
          conf.timeout_reboot_kexec = code
        end

        cp.parse('kexec') do
          conf.kexec_repository = cp.value(
            'repository',String,'/dev/shm/kexec_repository',Pathname
          )
        end

        cp.parse('pxe') do
          cp.parse('headers') do
            conf.pxe_header[:chain] = cp.value('dhcp',String,'')
            conf.pxe_header[:local] = cp.value('localboot',String,'')
            conf.pxe_header[:network] = cp.value('networkboot',String,'')
          end
        end

        cp.parse('hooks') do
          conf.use_ip_to_deploy = cp.value(
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

      return true
    end

    # Eventually load some specific commands for specific nodes that override generic commands
    #
    # Arguments
    # * nothing
    # Output
    # * return true in case of success, false otherwise
    def load_commands
      configfile = COMMANDS_FILE
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
        node = @common.nodes_desc.get_node_by_host(nodename)

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
      return true
    end

    # Load the version of Kadeploy
    #
    # Arguments
    # * nothing
    # Output
    # * nothing
    def load_version
      line = IO.readlines(VERSION_FILE)
      @common.version = line[0].strip
    end

    # Replace the substrings HOSTNAME_FQDN and HOSTNAME_SHORT in a string by a value
    #
    # Arguments
    # * str: string in which the HOSTNAME_FQDN and HOSTNAME_SHORT values must be replaced
    # * hostname: value used for the replacement
    # Output
    # * return the new string       
    def replace_hostname(str, hostname)
      if (str != nil) then
        cmd_to_expand = str.clone # we must use this temporary variable since sub() modify the strings
        save = str
        while cmd_to_expand.sub!("HOSTNAME_FQDN", hostname) != nil  do
          save = cmd_to_expand
        end
        while cmd_to_expand.sub!("HOSTNAME_SHORT", hostname.split(".")[0]) != nil  do
          save = cmd_to_expand
        end
        return save
      else
        return nil
      end
    end

    # Generate the commands used for a node
    #
    # Arguments
    # * hostname: hostname of the node
    # * cluster: cluster whom the node belongs to
    # Output
    # * return an instance of NodeCmd or raise an exception if the cluster specific config has not been read
    def generate_commands(hostname, cluster)
      cmd = Nodes::NodeCmd.new
      if @cluster_specific.has_key?(cluster) then
        cmd.reboot_soft = replace_hostname(@cluster_specific[cluster].cmd_soft_reboot, hostname)
        cmd.reboot_hard = replace_hostname(@cluster_specific[cluster].cmd_hard_reboot, hostname)
        cmd.reboot_very_hard = replace_hostname(@cluster_specific[cluster].cmd_very_hard_reboot, hostname)
        cmd.console = replace_hostname(@cluster_specific[cluster].cmd_console, hostname)
        cmd.power_on_soft = replace_hostname(@cluster_specific[cluster].cmd_soft_power_on, hostname)
        cmd.power_on_hard = replace_hostname(@cluster_specific[cluster].cmd_hard_power_on, hostname)
        cmd.power_on_very_hard = replace_hostname(@cluster_specific[cluster].cmd_very_hard_power_on, hostname)
        cmd.power_off_soft = replace_hostname(@cluster_specific[cluster].cmd_soft_power_off, hostname)
        cmd.power_off_hard = replace_hostname(@cluster_specific[cluster].cmd_hard_power_off, hostname)
        cmd.power_off_very_hard = replace_hostname(@cluster_specific[cluster].cmd_very_hard_power_off, hostname)
        cmd.power_status = replace_hostname(@cluster_specific[cluster].cmd_power_status, hostname)
        return cmd
      else
        $stderr.puts "Missing specific config file for the cluster #{cluster}"
        raise
      end
    end


    # Checks an hostname and adds it to the nodelist
    #
    # Arguments
    # * nodelist: the array containing the node list
    # * hostname: the hostname of the machine
    # Output
    # * return true in case of success, false otherwise
    def self.load_machine(nodelist, hostname)
      hostname.strip!
      if R_HOSTNAME =~ hostname then
        nodelist.push(hostname) unless hostname.empty?
        return true
      else
        error("Invalid hostname: #{hostname}")
        return false
      end
    end

    # Loads a machinelist file
    #
    # Arguments
    # * nodelist: the array containing the node list
    # * param: the command line parameter
    # Output
    # * return true in case of success, false otherwise
    def self.load_machinelist(nodelist, param)
      if (param == "-") then
        STDIN.read.split("\n").sort.uniq.each do |hostname|
          return false unless load_machine(nodelist,hostname)
        end
      else
        if File.readable?(param) then
          IO.readlines(param).sort.uniq.each do |hostname|
            return false unless load_machine(nodelist,hostname)
          end
        else
          error("The file #{param} cannot be read")
          return false
        end
      end

      return true
    end


##################################
#       Kadeploy specific        #
##################################


    # Add a node involved in the deployment to the exec_specific.node_set
    #
    # Arguments
    # * hostname: hostname of the node
    # * nodes_desc: set of nodes read from the configuration file
    # * exec_specific: open struct that contains some execution specific stuffs (modified)
    # Output
    # * return true if the node exists in the Kadeploy configuration, false otherwise
    def add_to_node_set(hostname, exec_specific)
      if Nodes::REGEXP_NODELIST =~ hostname
        hostnames = Nodes::NodeSet::nodes_list_expand("#{hostname}") 
      else
        hostnames = [hostname]
      end
      hostnames.each{|host|
        n = @common.nodes_desc.get_node_by_host(host)
        if (n != nil) then
          exec_specific.node_set.push(n)
        else
          return false
        end
      }
      return true
    end


##################################
#        Kastat specific         #
##################################

    # Load the kastat specific stuffs
    #
    # Arguments
    # * nothing
    # Output
    # * return true in case of success, false otherwise
    def Config.load_kastat_exec_specific()
      exec_specific = OpenStruct.new
      exec_specific.operation = String.new
      exec_specific.date_min = 0
      exec_specific.date_max = 0
      exec_specific.min_retries = 0
      exec_specific.min_rate = 0
      exec_specific.node_list = Array.new
      exec_specific.steps = Array.new
      exec_specific.fields = Array.new
      exec_specific.get_version = false
      exec_specific.chosen_server = String.new
      exec_specific.servers = Config.load_client_config_file
      exec_specific.kadeploy_server = String.new
      exec_specific.kadeploy_server_port = String.new
      exec_specific.workflow_id = String.new

      if Config.load_kastat_cmdline_options(exec_specific) then
        return exec_specific
      else
        return nil
      end
    end

    # Load the command-line options of kastat
    #
    # Arguments
    # * nothing
    # Output
    # * return true in case of success, false otherwise
    def Config.load_kastat_cmdline_options(exec_specific)
      opts = OptionParser::new do |opt|
        opt.summary_indent = "  "
        opt.summary_width = 32
        opt.banner = "Usage: kastat3 [options]"
        opt.separator "Contact: #{CONTACT_EMAIL}"
        opt.separator ""
        opt.separator "General options:"
        opt.on("-a", "--list-min-retries NB", "Print the statistics about the nodes that need several attempts") { |n|
          if /\A\d+\Z/ =~ n then
            exec_specific.operation = "list_retries"
            exec_specific.min_retries = n.to_i
          else
            error("Invalid number of minimum retries, ignoring the option")
            return false
          end
        }
        opt.on("-b", "--list-failure-rate", "Print the failure rate for the nodes") { |n|
          exec_specific.operation = "list_failure_rate"
        }
        opt.on("-c", "--list-min-failure-rate RATE", "Print the nodes which have a minimum failure-rate of RATE (0 <= RATE <= 100)") { |r|
          if ((/\A\d+/ =~ r) && ((r.to_i >= 0) && ((r.to_i <= 100)))) then
            exec_specific.operation = "list_min_failure_rate"
            exec_specific.min_rate = r.to_i
          else
            error("Invalid number for the minimum failure rate, ignoring the option")
            return false
          end
        }
        opt.on("-d", "--list-all", "Print all the information") { |r|
          exec_specific.operation = "list_all"
        }
        opt.on("-f", "--field FIELD", "Only print the given fields (user,hostname,step1,step2,step3,timeout_step1,timeout_step2,timeout_step3,retry_step1,retry_step2,retry_step3,start,step1_duration,step2_duration,step3_duration,env,md5,success,error)") { |f|
          exec_specific.fields.push(f)
        }
        opt.on("-l", "--last", "Only print the most recent information of selected machines") {
          exec_specific.operation = "list_last"
        }
        opt.on("-m", "--machine MACHINE", "Only print information about the given machines") { |hostname|
          return false unless load_machine(exec_specific.node_list, hostname)
        }
        opt.on("-s", "--step STEP", "Apply the retry filter on the given steps (1, 2 or 3)") { |s|
          exec_specific.steps.push(s) 
        }
        opt.on("-v", "--version", "Get the version") {
          exec_specific.get_version = true
        }
        opt.on("-w", "--workflow-id ID", "Get the stats of a specific deployment") { |w|
          exec_specific.operation = "print_workflow"
          exec_specific.workflow_id = w
        }
        opt.on("-x", "--date-min DATE", "Get the stats from this date (yyyy:mm:dd:hh:mm:ss)") { |d|
          exec_specific.date_min = d
        }
        opt.on("-y", "--date-max DATE", "Get the stats to this date") { |d|
          exec_specific.date_max = d
        }
        opt.on("--server STRING", "Specify the Kadeploy server to use") { |s|
          exec_specific.chosen_server = s
        }
      end
      @opts = opts
      begin
        opts.parse!(ARGV)
      rescue 
        error("Option parsing error: #{$!}")
        return false
      end

      if (exec_specific.chosen_server != "") then
        if not exec_specific.servers.has_key?(exec_specific.chosen_server) then
          error("The #{exec_specific.chosen_server} server is not defined in the configuration: #{(exec_specific.servers.keys - ["default"]).join(", ")} values are allowed")
          return false
        end
      else
        exec_specific.chosen_server = exec_specific.servers["default"]
      end
      exec_specific.kadeploy_server = exec_specific.servers[exec_specific.chosen_server][0]
      exec_specific.kadeploy_server_port = exec_specific.servers[exec_specific.chosen_server][1]

      return true if exec_specific.get_version
      if (exec_specific.operation == "") then
        error("You must choose an operation")
        return false
      end
      authorized_fields = ["user","hostname","step1","step2","step3", \
                           "timeout_step1","timeout_step2","timeout_step3", \
                           "retry_step1","retry_step2","retry_step3", \
                           "start", \
                           "step1_duration","step2_duration","step3_duration", \
                           "env","anonymous_env","md5", \
                           "success","error"]
      exec_specific.fields.each { |f|
        if (not authorized_fields.include?(f)) then
          error("The field \"#{f}\" does not exist")
          return false
        end
      }
      if (exec_specific.date_min != 0) then
        unless /^\d{4}:\d{2}:\d{2}:\d{2}:\d{2}:\d{2}$/ === exec_specific.date_min
          error("The date #{exec_specific.date_min} is not correct")
          return false
        else
          str = exec_specific.date_min.split(":")
          exec_specific.date_min = Time.mktime(str[0], str[1], str[2], str[3], str[4], str[5]).to_i
        end
      end
      if (exec_specific.date_max != 0) then
        unless /^\d{4}:\d{2}:\d{2}:\d{2}:\d{2}:\d{2}$/ === exec_specific.date_max
          error("The date #{exec_specific.date_max} is not correct")
          return false
        else
          str = exec_specific.date_max.split(":")
          exec_specific.date_max = Time.mktime(str[0], str[1], str[2], str[3], str[4], str[5]).to_i
        end
      end
      authorized_steps = ["1","2","3"]
      exec_specific.steps.each { |s|
         if (not authorized_steps.include?(s)) then
           error("The step \"#{s}\" does not exist")
           return false
         end
       }

      return true
    end

##################################
#       Kanodes specific         #
##################################

    # Load the kanodes specific stuffs
    #
    # Arguments
    # * nothing
    # Output
    # * return true in case of success, false otherwise
    def Config.load_kanodes_exec_specific()
      exec_specific = OpenStruct.new
      exec_specific.operation = String.new
      exec_specific.node_list = Array.new
      exec_specific.wid = String.new
      exec_specific.get_version = false
      exec_specific.chosen_server = String.new
      exec_specific.servers = Config.load_client_config_file
      exec_specific.kadeploy_server = String.new
      exec_specific.kadeploy_server_port = String.new

      if Config.load_kanodes_cmdline_options(exec_specific) then
        return exec_specific
      else
        return nil
      end
    end

    # Load the command-line options of kanodes
    #
    # Arguments
    # * nothing
    # Output
    # * return true in case of success, false otherwise
    def Config.load_kanodes_cmdline_options(exec_specific)
      opts = OptionParser::new do |opt|
        opt.summary_indent = "  "
        opt.summary_width = 28
        opt.banner = "Usage: kanodes3 [options]"
        opt.separator "Contact: #{CONTACT_EMAIL}"
        opt.separator ""
        opt.separator "General options:"
        opt.on("-d", "--get-deploy-state", "Get the deploy state of the nodes") {
          exec_specific.operation = "get_deploy_state"
        }
        opt.on("-f", "--file MACHINELIST", "Only print information about the given machines (- means stdin)")  { |f|
          return false unless load_machinelist(exec_specific.node_list, f)
        }
        opt.on("-m", "--machine MACHINE", "Only print information about the given machines") { |hostname|
          return false unless load_machine(exec_specific.node_list, hostname)
        }
        opt.on("-v", "--version", "Get the version") {
          exec_specific.get_version = true
        }
        opt.on("-w", "--workflow-id WID", "Specify a workflow id (this is use with the get_yaml_dump operation. If no wid is specified, the information of all the running worklfows will be dumped") { |w|
          exec_specific.wid = w
        }
        opt.on("-y", "--get-yaml-dump", "Get the yaml dump") {
          exec_specific.operation = "get_yaml_dump"
        }
        opt.on("--server STRING", "Specify the Kadeploy server to use") { |s|
          exec_specific.chosen_server = s
        }
      end
      @opts = opts
      begin
        opts.parse!(ARGV)
      rescue 
        error("Option parsing error: #{$!}")
        return false
      end

      if (exec_specific.chosen_server != "") then
        if not exec_specific.servers.has_key?(exec_specific.chosen_server) then
          error("The #{exec_specific.chosen_server} server is not defined in the configuration: #{(exec_specific.servers.keys - ["default"]).join(", ")} values are allowed")
          return false
        end
      else
        exec_specific.chosen_server = exec_specific.servers["default"]
      end
      exec_specific.kadeploy_server = exec_specific.servers[exec_specific.chosen_server][0]
      exec_specific.kadeploy_server_port = exec_specific.servers[exec_specific.chosen_server][1]

      if ((exec_specific.operation == "") && (not exec_specific.get_version)) then
        error("You must choose an operation")
        return false
      end
      return true
    end

##################################
#       Kareboot specific        #
##################################

    # Load the kareboot specific stuffs
    #
    # Arguments
    # * nothing
    # Output
    # * return true in case of success, false otherwise
    def Config.load_kareboot_exec_specific()
      exec_specific = OpenStruct.new
      exec_specific.verbose_level = nil
      exec_specific.nodesetid = 0
      exec_specific.node_set = Nodes::NodeSet.new(exec_specific.nodesetid)
      exec_specific.node_array = Array.new
      exec_specific.check_demolishing = false
      exec_specific.true_user = USER
      exec_specific.user = nil
      exec_specific.load_env_kind = "db"
      exec_specific.env_arg = String.new
      exec_specific.environment = EnvironmentManagement::Environment.new
      exec_specific.block_device = String.new
      exec_specific.deploy_part = String.new
      exec_specific.breakpoint_on_microstep = "none"
      exec_specific.pxe_profile_msg = String.new
      exec_specific.pxe_upload_files = Array.new
      exec_specific.pxe_profile_singularities = nil
      exec_specific.key = String.new
      exec_specific.nodes_ok_file = String.new
      exec_specific.nodes_ko_file = String.new
      exec_specific.reboot_level = "soft"
      exec_specific.wait = true
      exec_specific.get_version = false
      exec_specific.chosen_server = String.new
      exec_specific.servers = Config.load_client_config_file
      exec_specific.kadeploy_server = String.new
      exec_specific.kadeploy_server_port = String.new
      exec_specific.multi_server = false
      exec_specific.debug = false
      exec_specific.reboot_classical_timeout = nil
      exec_specific.vlan = nil
      exec_specific.ip_in_vlan = nil

      if Config.load_kareboot_cmdline_options(exec_specific) then
        return exec_specific
      else
        return nil
      end
    end

    # Load the command-line options of kareboot
    #
    # Arguments
    # * nothing
    # Output
    # * return true in case of success, false otherwise
    def Config.load_kareboot_cmdline_options(exec_specific)
      opts = OptionParser::new do |opt|
        opt.summary_indent = "  "
        opt.summary_width = 32
        opt.banner = "Usage: kareboot3 [options]"
        opt.separator "Contact: #{CONTACT_EMAIL}"
        opt.separator ""
        opt.separator "General options:"
        opt.on("-b", "--block-device BLOCKDEVICE", "Specify the block device to use") { |b|
          if /\A[\w\/]+\Z/ =~ b then
            exec_specific.block_device = b
          else
            error("Invalid block device")
            return false
          end
        }
        opt.on("-c", "--check-demolishing-tag", "Check if some nodes was deployed with an environment that have the demolishing tag") {
          exec_specific.check_demolishing = true
        }
        opt.on("-d", "--debug-mode", "Activate the debug mode") {
          exec_specific.debug = true
        }
        opt.on("-e", "--env-name ENVNAME", "Name of the recorded environment") { |e|
          exec_specific.env_arg = e
        }
        opt.on("-f", "--file MACHINELIST", "Files containing list of nodes (- means stdin)")  { |f|
          return false unless load_machinelist(exec_specific.node_array, f)
        }
        opt.on("-k", "--key [FILE]", "Public key to copy in the root's authorized_keys, if no argument is specified, use the authorized_keys") { |f|
          if (f != nil) then
            if (f =~ R_HTTP) then
              exec_specific.key = f
            else
              if not File.readable?(f) then
                error("The file #{f} cannot be read")
                return false
              else
                exec_specific.key = File.expand_path(f)
              end
            end
          else
            authorized_keys = File.expand_path("~/.ssh/authorized_keys")
            if File.readable?(authorized_keys) then
              exec_specific.key = authorized_keys
            else
              error("The authorized_keys file #{authorized_keys} cannot be read")
              return false
            end
          end
        }
        opt.on("-l", "--reboot-level VALUE", "Reboot level (soft, hard, very_hard)") { |l|
          if l =~ /\A(soft|hard|very_hard)\Z/ then
            exec_specific.reboot_level = l
          else
            error("Invalid reboot level")
            return false
          end
        }   
        opt.on("-m", "--machine MACHINE", "Reboot the given machines") { |hostname|
          return false unless load_machine(exec_specific.node_array, hostname)
        }
        opt.on("--multi-server", "Activate the multi-server mode") {
          exec_specific.multi_server = true
        }
        opt.on("-n", "--output-ko-nodes FILENAME", "File that will contain the nodes not correctly rebooted")  { |f|
          exec_specific.nodes_ko_file = f
        }
        opt.on("-o", "--output-ok-nodes FILENAME", "File that will contain the nodes correctly rebooted")  { |f|
          exec_specific.nodes_ok_file = f
        }
        opt.on("-p", "--partition-number NUMBER", "Specify the partition number to use") { |p|
          exec_specific.deploy_part = p
        }
        opt.on("-r", "--reboot-kind REBOOT_KIND", "Specify the reboot kind (set_pxe, simple_reboot, deploy_env, env_recorded)") { |k|
          exec_specific.reboot_kind = k
        }
        opt.on("-u", "--user USERNAME", "Specify the user") { |u|
          if /\A\w+\Z/ =~ u then
            exec_specific.user = u
          else
            error("Invalid user name")
            return false
          end
        }
        opt.on("-v", "--version", "Get the version") {
          exec_specific.get_version = true
        }
        opt.on("--vlan VLANID", "Set the VLAN") { |id|
          exec_specific.vlan = id
        }
        opt.on("-w", "--set-pxe-profile FILE", "Set the PXE profile (use with caution)") { |f|
          if not File.readable?(f) then
            error("The file #{f} cannot be read")
            return false
          else
            IO.readlines(f).each { |l|
              exec_specific.pxe_profile_msg.concat(l)
            }
          end
        }
        opt.on("--set-pxe-pattern FILE", "Specify a file containing the substituation of a pattern for each node in the PXE profile (the NODE_SINGULARITY pattern must be used in the PXE profile)") { |f|
          if not File.readable?(f) then
            error("The file #{f} cannot be read")
            return false
          else
            exec_specific.pxe_profile_singularities = Hash.new
            IO.readlines(f).each { |l|
              if !(/^#/ =~ l) and !(/^$/ =~ l) then #we ignore commented and empty lines
                content = l.split(",")
                exec_specific.pxe_profile_singularities[content[0]] = content[1].strip
              end
            }
          end
        }
        opt.on("-x", "--upload-pxe-files FILES", "Upload a list of files (file1,file2,file3) to the PXE kernels repository. Those files will then be available with the prefix FILES_PREFIX-- ") { |l|
          l.split(",").each { |file|
            if (file =~ R_HTTP) then
              exec_specific.pxe_upload_files.push(file) 
            else
              f = File.expand_path(file)
              if not File.readable?(f) then
                error("The file #{f} cannot be read")
                return false
              else
                exec_specific.pxe_upload_files.push(f) 
              end
            end
          }
        }
        opt.on("--env-version NUMBER", "Specify the environment version") { |v|
          if /\A\d+\Z/ =~ v then
            exec_specific.env_version = v
          else
            error("Invalid version number")
            return false
          end
        }
        opt.on("--no-wait", "Do not wait the end of the reboot") {
          exec_specific.wait = false
        }
        opt.on("--server STRING", "Specify the Kadeploy server to use") { |s|
          exec_specific.chosen_server = s
        } 
        opt.on("-V", "--verbose-level VALUE", "Verbose level between 0 to 5") { |d|
          if d =~ /\A\d+\Z/ then
            exec_specific.verbose_level = d.to_i
          else
            error("Invalid verbose level")
            return false
          end
        }
        opt.on("--reboot-classical-timeout V", "Overload the default timeout for classical reboots") { |t|
          if (t =~ /\A\d+\Z/) then
            exec_specific.reboot_classical_timeout = t
          else
            error("A number is required for the reboot classical timeout")
          end
        }
      end
      @opts = opts
      begin
        opts.parse!(ARGV)
      rescue 
        error("Option parsing error: #{$!}")
        return false
      end

      if (exec_specific.chosen_server != "") then
        if not exec_specific.servers.has_key?(exec_specific.chosen_server) then
          error("The #{exec_specific.chosen_server} server is not defined in the configuration: #{(exec_specific.servers.keys - ["default"]).join(", ")} values are allowed")
          return false
        end
      else
        exec_specific.chosen_server = exec_specific.servers["default"]
      end
      exec_specific.kadeploy_server = exec_specific.servers[exec_specific.chosen_server][0]
      exec_specific.kadeploy_server_port = exec_specific.servers[exec_specific.chosen_server][1]

      return true if exec_specific.get_version

      if exec_specific.node_array.empty? then
        error("No node is chosen")
        return false
      end    
      if (exec_specific.verbose_level != nil) && ((exec_specific.verbose_level > 5) || (exec_specific.verbose_level < 0)) then
        error("Invalid verbose level")
        return false
      end
      authorized_ops = ["set_pxe", "simple_reboot", "deploy_env", "env_recorded"]
      if not authorized_ops.include?(exec_specific.reboot_kind) then
        error("Invalid kind of reboot: #{exec_specific.reboot_kind}")
        return false
      end        
      if (exec_specific.reboot_kind == "set_pxe") && (exec_specific.pxe_profile_msg == "") then
        error("The set_pxe reboot must be used with the -w option")
        return false
      end
      if (exec_specific.reboot_kind == "env_recorded") then
        if (exec_specific.env_arg == "") then
          error("An environment must be specified must be with the env_recorded kind of reboot")
          return false
        end
        if (exec_specific.deploy_part == "") then
          error("A partition number must be specified must be with the env_recorded kind of reboot")
          return false
        end 
      end      
      if (exec_specific.key != "") && (exec_specific.reboot_kind != "deploy_env") then
        error("The -k option can be only used with the deploy_env reboot kind")
        return false
      end
      if (exec_specific.nodes_ok_file != "") && (exec_specific.nodes_ok_file == exec_specific.nodes_ko_file) then
        error("The files used for the output of the OK and the KO nodes must not be the same")
        return false
      end
      if not exec_specific.wait then
        if (exec_specific.nodes_ok_file != "") || (exec_specific.nodes_ko_file != "") then
          error("-o/--output-ok-nodes and/or -n/--output-ko-nodes cannot be used with --no-wait")
          return false          
        end
        if (exec_specific.key != "") then
          error("-k/--key cannot be used with --no-wait")
          return false
        end
      end
      return true
    end

##################################
#      Kaconsole specific        #
##################################

    # Load the kaconsole specific stuffs
    #
    # Arguments
    # * nothing
    # Output
    # * return true in case of success, false otherwise
    def Config.load_kaconsole_exec_specific()
      exec_specific = OpenStruct.new
      exec_specific.node = nil
      exec_specific.get_version = false
      exec_specific.true_user = USER
      exec_specific.chosen_server = String.new
      exec_specific.servers = Config.load_client_config_file
      exec_specific.kadeploy_server = String.new
      exec_specific.kadeploy_server_port = String.new

      if Config.load_kaconsole_cmdline_options(exec_specific) then
        return exec_specific
      else
        return nil
      end
    end

    # Load the command-line options of kaconsole
    #
    # Arguments
    # * nothing
    # Output
    # * return true in case of success, false otherwise
    def Config.load_kaconsole_cmdline_options(exec_specific)
      opts = OptionParser::new do |opt|
        opt.summary_indent = "  "
        opt.summary_width = 28
        opt.banner = "Usage: kaconsole3 [options]"
        opt.separator "Contact: #{CONTACT_EMAIL}"
        opt.separator ""
        opt.separator "General options:"
        opt.on("-m", "--machine MACHINE", "Obtain a console on the given machine") { |hostname|
          hostname.strip!
          unless R_HOSTNAME =~ hostname
            error("Invalid hostname: #{hostname}")
            return false
          end
          exec_specific.node = hostname
        }
        opt.on("-v", "--version", "Get the version") {
          exec_specific.get_version = true
        }
      end
      @opts = opts
      begin
        opts.parse!(ARGV)
      rescue 
        error("Option parsing error: #{$!}")
        return false
      end
  
      if (exec_specific.chosen_server != "") then
        if not exec_specific.servers.has_key?(exec_specific.chosen_server) then
          error("The #{exec_specific.chosen_server} server is not defined in the configuration: #{(exec_specific.servers.keys - ["default"]).join(", ")} values are allowed")
          return false
        end
      else
        exec_specific.chosen_server = exec_specific.servers["default"]
      end
      exec_specific.kadeploy_server = exec_specific.servers[exec_specific.chosen_server][0]
      exec_specific.kadeploy_server_port = exec_specific.servers[exec_specific.chosen_server][1]

      return true if exec_specific.get_version
      if (exec_specific.node == nil)then
        error("You must choose one node")
        return false
      end
      return true
    end




##################################
#        Kapower specific        #
##################################

    # Load the kapower specific stuffs
    #
    # Arguments
    # * nothing
    # Output
    # * return true in case of success, false otherwise
    def Config.load_kapower_exec_specific()
      exec_specific = OpenStruct.new
      exec_specific.verbose_level = nil
      exec_specific.node_set = Nodes::NodeSet.new
      exec_specific.node_array = Array.new
      exec_specific.true_user = USER
      exec_specific.nodes_ok_file = String.new
      exec_specific.nodes_ko_file = String.new
      exec_specific.breakpoint_on_microstep = "none"
      exec_specific.operation = ""
      exec_specific.level = "soft"
      exec_specific.wait = true
      exec_specific.debug = false
      exec_specific.get_version = false
      exec_specific.chosen_server = String.new
      exec_specific.servers = Config.load_client_config_file
      exec_specific.kadeploy_server = String.new
      exec_specific.kadeploy_server_port = String.new
      exec_specific.multi_server = false
      exec_specific.debug = false
      
      if Config.load_kapower_cmdline_options(exec_specific) then
        return exec_specific
      else
        return nil
      end
    end

    # Load the command-line options of kapower
    #
    # Arguments
    # * nothing
    # Output
    # * return true in case of success, false otherwise
    def Config.load_kapower_cmdline_options(exec_specific)
      opts = OptionParser::new do |opt|
        opt.summary_indent = "  "
        opt.summary_width = 30
        opt.banner = "Usage: kapower3 [options]"
        opt.separator "Contact: #{CONTACT_EMAIL}"
        opt.separator ""
        opt.separator "General options:"
        opt.on("-d", "--debug-mode", "Activate the debug mode") {
          exec_specific.debug = true
        }
        opt.on("-f", "--file MACHINELIST", "Files containing list of nodes (- means stdin)")  { |f|
          return false unless load_machinelist(exec_specific.node_array,f)
        }
        opt.on("-l", "--level VALUE", "Level (soft, hard, very_hard)") { |l|
          if l =~ /\A(soft|hard|very_hard)\Z/ then
            exec_specific.level = l
          else
            error("Invalid level")
            return false
          end
        }   
        opt.on("-m", "--machine MACHINE", "Operate on the given machines") { |hostname|
          return false unless load_machine(exec_specific.node_array, hostname)
        }
        opt.on("--multi-server", "Activate the multi-server mode") {
          exec_specific.multi_server = true
        }
        opt.on("-n", "--output-ko-nodes FILENAME", "File that will contain the nodes on which the operation has not been correctly performed")  { |f|
          exec_specific.nodes_ko_file = f
        }
        opt.on("-o", "--output-ok-nodes FILENAME", "File that will contain the nodes on which the operation has been correctly performed")  { |f|
          exec_specific.nodes_ok_file = f
        }
        opt.on("--off", "Shutdown the nodes") {
          exec_specific.operation = "off"
        }
        opt.on("--on", "Power on the nodes") {
          exec_specific.operation = "on"
        }      
        opt.on("--status", "Get the status of the nodes") {
          exec_specific.operation = "status"
        }
        opt.on("-v", "--version", "Get the version") {
          exec_specific.get_version = true
        }
        opt.on("--no-wait", "Do not wait the end of the power operation") {
          exec_specific.wait = false
        }
        opt.on("--server STRING", "Specify the Kadeploy server to use") { |s|
          exec_specific.chosen_server = s
        } 
        opt.on("-V", "--verbose-level VALUE", "Verbose level between 0 to 5") { |d|
          if d =~ /\A\d+\Z/ then
            exec_specific.verbose_level = d.to_i
          else
            error("Invalid verbose level")
            return false
          end
        }
      end
      @opts = opts
      begin
        opts.parse!(ARGV)
      rescue 
        error("Option parsing error: #{$!}")
        return false
      end

      if (exec_specific.chosen_server != "") then
        if not exec_specific.servers.has_key?(exec_specific.chosen_server) then
          error("The #{exec_specific.chosen_server} server is not defined in the configuration: #{(exec_specific.servers.keys - ["default"]).join(", ")} values are allowed")
          return false
        end
      else
        exec_specific.chosen_server = exec_specific.servers["default"]
      end
      exec_specific.kadeploy_server = exec_specific.servers[exec_specific.chosen_server][0]
      exec_specific.kadeploy_server_port = exec_specific.servers[exec_specific.chosen_server][1]

      return true if exec_specific.get_version

      if exec_specific.node_array.empty? then
        error("No node is chosen")
        return false
      end    
      if (exec_specific.verbose_level != nil) && ((exec_specific.verbose_level > 5) || (exec_specific.verbose_level < 0)) then
        error("Invalid verbose level")
        return false
      end
      if (exec_specific.operation == "") then
        error("No operation is chosen")
        return false
      end
      if (exec_specific.nodes_ok_file != "") && (exec_specific.nodes_ok_file == exec_specific.nodes_ko_file) then
        error("The files used for the output of the OK and the KO nodes must not be the same")
        return false
      end
      return true
    end
  end
  
  class CommonConfig
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
    attr_accessor :nodes_desc     #information about all the nodes
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
      @nodes_desc = Nodes::NodeSet.new
      @cache = {}
      @pxe = {}
      @auth = {}
    end
  end

  
  class ClusterSpecificConfig
    attr_accessor :name
    attr_accessor :deploy_kernel
    attr_accessor :deploy_kernel_args
    attr_accessor :deploy_initrd
    attr_accessor :deploy_supported_fs
    attr_accessor :kexec_repository
    attr_accessor :block_device
    attr_accessor :deploy_part
    attr_accessor :prod_part
    attr_accessor :tmp_part
    attr_accessor :swap_part
    attr_accessor :workflow_steps   #Array of MacroStep
    attr_accessor :timeout_reboot_classical
    attr_accessor :timeout_reboot_kexec
    attr_accessor :cmd_soft_reboot
    attr_accessor :cmd_hard_reboot
    attr_accessor :cmd_very_hard_reboot
    attr_accessor :cmd_console
    attr_accessor :cmd_soft_power_off
    attr_accessor :cmd_hard_power_off
    attr_accessor :cmd_very_hard_power_off
    attr_accessor :cmd_soft_power_on
    attr_accessor :cmd_hard_power_on
    attr_accessor :cmd_very_hard_power_on
    attr_accessor :cmd_power_status
    attr_accessor :group_of_nodes #Hashtable (key is a command name)
    attr_accessor :partitioning_script
    attr_accessor :bootloader_script
    attr_accessor :prefix
    attr_accessor :drivers
    attr_accessor :pxe_header
    attr_accessor :kernel_params
    attr_accessor :nfsroot_kernel
    attr_accessor :nfsroot_params
    attr_accessor :admin_pre_install
    attr_accessor :admin_post_install
    attr_accessor :use_ip_to_deploy

    # Constructor of ClusterSpecificConfig
    #
    # Arguments
    # * nothing
    # Output
    # * nothing
    def initialize
      @workflow_steps = Array.new
      @deploy_kernel_args = ""
      @deploy_supported_fs = []
      @kexec_repository = '/tmp/karepository'
      @group_of_nodes = Hash.new
      @pxe_header = {}
      @use_ip_to_deploy = false
    end


    # Duplicate a ClusterSpecificConfig instance but the workflow steps
    #
    # Arguments
    # * dest: destination ClusterSpecificConfig instance
    # * workflow_steps: array of MacroStep
    # Output
    # * nothing      
    def duplicate_but_steps(dest, workflow_steps)
      dest.name = @name
      dest.workflow_steps = workflow_steps
      dest.deploy_kernel = @deploy_kernel.clone
      dest.deploy_kernel_args = @deploy_kernel_args.clone
      dest.deploy_initrd = @deploy_initrd.clone
      dest.deploy_supported_fs = @deploy_supported_fs.clone
      dest.block_device = @block_device.clone
      dest.deploy_part = @deploy_part.clone
      dest.prod_part = @prod_part.clone
      dest.tmp_part = @tmp_part.clone
      dest.swap_part = @swap_part.clone if (@swap_part != nil)
      dest.timeout_reboot_classical = @timeout_reboot_classical
      dest.timeout_reboot_kexec = @timeout_reboot_kexec
      dest.cmd_soft_reboot = @cmd_soft_reboot.clone if (@cmd_soft_reboot != nil)
      dest.cmd_hard_reboot = @cmd_hard_reboot.clone if (@cmd_hard_reboot != nil)
      dest.cmd_very_hard_reboot = @cmd_very_hard_reboot.clone if (@cmd_very_hard_reboot)
      dest.cmd_console = @cmd_console.clone
      dest.cmd_soft_power_on = @cmd_soft_power_on.clone if (@cmd_soft_power_on != nil)
      dest.cmd_hard_power_on = @cmd_hard_power_on.clone if (@cmd_hard_power_on != nil)
      dest.cmd_very_hard_power_on = @cmd_very_hard_power_on.clone if (@cmd_very_hard_power_on != nil)
      dest.cmd_soft_power_off = @cmd_soft_power_off.clone if (@cmd_soft_power_off != nil)
      dest.cmd_hard_power_off = @cmd_hard_power_off.clone if (@cmd_hard_power_off != nil) 
      dest.cmd_very_hard_power_off = @cmd_very_hard_power_off.clone if (@cmd_very_hard_power_off != nil)
      dest.cmd_power_status = @cmd_power_status.clone if (@cmd_power_status != nil)
      dest.group_of_nodes = @group_of_nodes.clone
      dest.drivers = @drivers.clone if (@drivers != nil)
      dest.pxe_header = Marshal.load(Marshal.dump(@pxe_header))
      dest.kernel_params = @kernel_params.clone if (@kernel_params != nil)
      dest.nfsroot_kernel = @nfsroot_kernel.clone if (@nfsroot_kernel != nil)
      dest.nfsroot_params = @nfsroot_params.clone if (@nfsroot_params != nil)
      dest.admin_pre_install = @admin_pre_install.clone if (@admin_pre_install != nil)
      dest.admin_post_install = @admin_post_install.clone if (@admin_post_install != nil)
      dest.partitioning_script = @partitioning_script.clone
      dest.bootloader_script = @bootloader_script.clone
      dest.prefix = @prefix.dup
      dest.use_ip_to_deploy = @use_ip_to_deploy
    end
    
    # Duplicate a ClusterSpecificConfig instance
    #
    # Arguments
    # * dest: destination ClusterSpecificConfig instance
    # Output
    # * nothing      
    def duplicate_all(dest)
      dest.name = @name
      dest.workflow_steps = Array.new
      @workflow_steps.each_index { |i|
        dest.workflow_steps[i] = Marshal.load(Marshal.dump(@workflow_steps[i]))
      }
      dest.deploy_kernel = @deploy_kernel.clone
      dest.deploy_kernel_args = @deploy_kernel_args.clone
      dest.deploy_initrd = @deploy_initrd.clone
      dest.deploy_supported_fs = @deploy_supported_fs.clone
      dest.kexec_repository = @kexec_repository.clone
      dest.block_device = @block_device.clone
      dest.deploy_part = @deploy_part.clone
      dest.prod_part = @prod_part.clone
      dest.tmp_part = @tmp_part.clone
      dest.swap_part = @swap_part.clone if (@swap_part != nil)
      dest.timeout_reboot_classical = @timeout_reboot_classical
      dest.timeout_reboot_kexec = @timeout_reboot_kexec
      dest.cmd_soft_reboot = @cmd_soft_reboot.clone if (@cmd_soft_reboot != nil)
      dest.cmd_hard_reboot = @cmd_hard_reboot.clone if (@cmd_hard_reboot != nil)
      dest.cmd_very_hard_reboot = @cmd_very_hard_reboot.clone if (@cmd_very_hard_reboot)
      dest.cmd_console = @cmd_console.clone
      dest.cmd_soft_power_on = @cmd_soft_power_on.clone if (@cmd_soft_power_on != nil)
      dest.cmd_hard_power_on = @cmd_hard_power_on.clone if (@cmd_hard_power_on != nil)
      dest.cmd_very_hard_power_on = @cmd_very_hard_power_on.clone if (@cmd_very_hard_power_on != nil)
      dest.cmd_soft_power_off = @cmd_soft_power_off.clone if (@cmd_soft_power_off != nil)
      dest.cmd_hard_power_off = @cmd_hard_power_off.clone if (@cmd_hard_power_off != nil) 
      dest.cmd_very_hard_power_off = @cmd_very_hard_power_off.clone if (@cmd_very_hard_power_off != nil)
      dest.cmd_power_status = @cmd_power_status.clone if (@cmd_power_status != nil)
      dest.group_of_nodes = @group_of_nodes.clone
      dest.drivers = @drivers.clone if (@drivers != nil)
      dest.pxe_header = Marshal.load(Marshal.dump(@pxe_header))
      dest.kernel_params = @kernel_params.clone if (@kernel_params != nil)
      dest.nfsroot_kernel = @nfsroot_kernel.clone if (@nfsroot_kernel != nil)
      dest.nfsroot_params = @nfsroot_params.clone if (@nfsroot_params != nil)
      dest.admin_pre_install = @admin_pre_install.clone if (@admin_pre_install != nil)
      dest.admin_post_install = @admin_post_install.clone if (@admin_post_install != nil)
      dest.partitioning_script = @partitioning_script.clone
      dest.bootloader_script = @bootloader_script.clone
      dest.prefix = @prefix.dup
      dest.use_ip_to_deploy = @use_ip_to_deploy
    end


    # Get the list of the macro step instances associed to a macro step
    #
    # Arguments
    # * name: name of the macro step
    # Output
    # * return the array of the macro step instances associed to a macro step or nil if the macro step name does not exist
    def get_macro_step(name)
      @workflow_steps.each { |elt| return elt if (elt.name == name) }
      return nil
    end

    # Replace a macro step
    #
    # Arguments
    # * name: name of the macro step
    # * new_instance: new instance array ([instance_name, instance_max_retries, instance_timeout])
    # Output
    # * nothing
    def replace_macro_step(name, new_instance)
      @workflow_steps.delete_if { |elt|
        elt.name == name
      }
      instances = Array.new
      instances.push(new_instance)
      macro_step = MacroStep.new(name, instances)
      @workflow_steps.push(macro_step)
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
end
