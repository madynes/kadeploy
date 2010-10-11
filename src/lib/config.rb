# Kadeploy 3.1
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2010
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

#Kadeploy libs
require 'environment'
require 'nodes'
require 'debug'
require 'checkrights'
require 'error'

#Ruby libs
require 'optparse'
require 'ostruct'
require 'fileutils'
require 'resolv'

module ConfigInformation
  CONFIGURATION_FOLDER = ENV['KADEPLOY_CONFIG_DIR']
  COMMANDS_FILE = File.join(CONFIGURATION_FOLDER, "cmd")
  NODES_FILE = File.join(CONFIGURATION_FOLDER, "nodes")
  VERSION_FILE = File.join(CONFIGURATION_FOLDER, "version")
  COMMON_CONFIGURATION_FILE = File.join(CONFIGURATION_FOLDER, "conf")
  CLUSTER_CONFIGURATION_FILE = File.join(CONFIGURATION_FOLDER, "clusters")
  CLIENT_CONFIGURATION_FILE = File.join(CONFIGURATION_FOLDER, "client_conf")
  SPECIFIC_CONFIGURATION_FILE_PREFIX = File.join(CONFIGURATION_FOLDER, "specific_conf_")
  PARTITION_FILE_PREFIX = File.join(CONFIGURATION_FOLDER, "partition_file_")
  USER = `id -nu`.chomp
  CONTACT_EMAIL = "kadeploy3-users@lists.gforge.inria.fr"

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
          res = load_common_config_file
          @cluster_specific = Hash.new
          res = res && load_cluster_specific_config_files
          res = res && load_nodes_config_file
          res = res && load_commands
          res = res && load_version
          raise "Problem in configuration" if not res
        else
          raise "Unsane configuration"
        end
      end
    end

    # Check the config of the Kadeploy tools
    #
    # Arguments
    # * kind: tool (kadeploy, kaenv, karights, kastat, kareboot, kaconsole, kanodes)
    # Output
    # * calls the chack_config method that correspond to the selected tool
    def check_client_config(kind, exec_specific_config, db, client)
      method = "check_#{kind.split("_")[0]}_config".to_sym
      return send(method, exec_specific_config, db, client)
    end

    def check_kadeploy_config(exec_specific_config, db, client)
      #Nodes check
      exec_specific_config.node_array.each { |hostname|
        if not add_to_node_set(hostname, exec_specific_config) then
          Debug::distant_client_error("The node #{hostname} does not exist", client)
          return KadeployAsyncError::NODE_NOT_EXIST
        end
      }
      
      #VLAN
      if (exec_specific_config.vlan != nil) then
        if ((@common.vlan_hostname_suffix == "") || (@common.set_vlan_cmd == "")) then
          Debug::distant_client_error("No VLAN can be used on this site (some configuration is missing)", client)
          return KadeployAsyncError::VLAN_MGMT_DISABLED
        else
          dns = Resolv::DNS.new
          exec_specific_config.ip_in_vlan = Hash.new
          exec_specific_config.node_array.each { |hostname|
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
          b = @cluster_specific[cluster].block_device
          p = @cluster_specific[cluster].deploy_part
          b = exec_specific_config.block_device if (exec_specific_config.block_device != "")
          p = exec_specific_config.deploy_part if (exec_specific_config.deploy_part != "")
          part = b + p
          allowed_to_deploy = CheckRights::CheckRightsFactory.create(@common.rights_kind,
                                                                     exec_specific_config.true_user,
                                                                     client, set, db, part).granted?
        end
      }
      if (not allowed_to_deploy) then
        Debug::distant_client_error("You do not have the right to deploy on all the nodes", client)
        return KadeployAsyncError::NO_RIGHT_TO_DEPLOY
      end

      #Environment load
      case exec_specific_config.load_env_kind
      when "file"
        if (exec_specific_config.environment.load_from_file(exec_specific_config.load_env_arg,
                                                            exec_specific_config.load_env_content,
                                                            @common.almighty_env_users,
                                                            exec_specific_config.true_user,
                                                            @common.kadeploy_cache_dir,
                                                            client,
                                                            false) == false) then
          return KadeployAsyncError::LOAD_ENV_FROM_FILE_ERROR
        end
      when "db"
        if (exec_specific_config.environment.load_from_db(exec_specific_config.load_env_arg,
                                                          exec_specific_config.env_version,
                                                          exec_specific_config.user,
                                                          exec_specific_config.true_user,
                                                          db,
                                                          client) == false) then
          return KadeployAsyncError::LOAD_ENV_FROM_DB_ERROR
        end
      else
        Debug::distant_client_error("You must choose an environment", client)
        return KadeployAsyncError::NO_ENV_CHOSEN
      end

      return KadeployAsyncError::NO_ERROR
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
          exec_specific_config.node_array.each { |hostname|
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
          b = @cluster_specific[cluster].block_device
          p = @cluster_specific[cluster].deploy_part
          b = exec_specific_config.block_device if (exec_specific_config.block_device != "")
          p = exec_specific_config.deploy_part if (exec_specific_config.deploy_part != "")
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
        if (exec_specific_config.environment.load_from_db(exec_specific_config.env_arg,
                                                          exec_specific_config.env_version,
                                                          exec_specific_config.user,
                                                          exec_specific_config.true_user,
                                                          db,
                                                          client) == false) then
          return KarebootAsyncError::LOAD_ENV_FROM_DB_ERROR
        end
      end
      return KarebootAsyncError::NO_ERROR
    end

    def check_kaenv_config(exec_specific_config, db, client)
      return 0
    end

    def check_karights_config(exec_specific_config, db, client)
      if not @common.almighty_env_users.include?(exec_specific_config.true_user) then
        Debug::distant_client_error("Only administrators are allowed to set rights", client)
        return 1
      end
      return 0
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

    # Load the kadeploy specific stuffs
    #
    # Arguments
    # * nothing
    # Output
    # * exec_specific: return an open struct that contains the execution specific information
    #                  or nil if the command line is not correct
    def Config.load_kadeploy_exec_specific()
      exec_specific = OpenStruct.new
      exec_specific.environment = EnvironmentManagement::Environment.new
      exec_specific.node_set = Nodes::NodeSet.new
      exec_specific.node_array = Array.new
      exec_specific.load_env_kind = String.new
      exec_specific.load_env_arg = String.new
      exec_specific.load_env_content = String.new
      exec_specific.env_version = nil #By default we load the latest version
      exec_specific.user = USER #By default, we use the current user
      exec_specific.true_user = USER
      exec_specific.block_device = String.new
      exec_specific.deploy_part = String.new
      exec_specific.verbose_level = nil
      exec_specific.debug = false
      exec_specific.script = String.new
      exec_specific.key = String.new
      exec_specific.reformat_tmp = false
      exec_specific.pxe_profile_msg = String.new
      exec_specific.pxe_upload_files = Array.new
      exec_specific.pxe_profile_singularities = nil
      exec_specific.steps = Array.new
      exec_specific.ignore_nodes_deploying = false
      exec_specific.breakpoint_on_microstep = String.new
      exec_specific.breakpointed = false
      exec_specific.custom_operations_file = String.new
      exec_specific.custom_operations = nil
      exec_specific.disable_bootloader_install = false
      exec_specific.disable_disk_partitioning = false
      exec_specific.nodes_ok_file = String.new
      exec_specific.nodes_ko_file = String.new
      exec_specific.nodes_state = Hash.new
      exec_specific.write_workflow_id = String.new
      exec_specific.get_version = false
      exec_specific.prefix_in_cache = String.new
      exec_specific.chosen_server = String.new
      exec_specific.servers = Config.load_client_config_file
      exec_specific.multi_server = false
      exec_specific.kadeploy_server = String.new
      exec_specific.kadeploy_server_port = String.new
      exec_specific.reboot_classical_timeout = nil
      exec_specific.reboot_kexec_timeout = nil
      exec_specific.vlan = nil
      exec_specific.ip_in_vlan = nil
      
      if Config.load_kadeploy_cmdline_options(exec_specific) then
        return exec_specific
      else
        return nil
      end
    end

    # Set the state of the node from the deployment workflow point of view
    #
    # Arguments
    # * hostname: hostname concerned by the update
    # * macro_step: name of the macro step
    # * micro_step: name of the micro step
    # * state: state of the node (ok/ko)
    # Output
    # * nothing
    def set_node_state(hostname, macro_step, micro_step, state)
      #This is not performed when nodes_state is unitialized (when called from Kareboot for instance)
      if (@exec_specific.nodes_state != nil) then
        if not @exec_specific.nodes_state.has_key?(hostname) then
          @exec_specific.nodes_state[hostname] = Array.new
        end
        @exec_specific.nodes_state[hostname][0] = { "macro-step" => macro_step } if macro_step != ""
        @exec_specific.nodes_state[hostname][1] = { "micro-step" => micro_step } if micro_step != ""
        @exec_specific.nodes_state[hostname][2] = { "state" => state } if state != ""
      end
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
      if not File.readable?(COMMON_CONFIGURATION_FILE) then
        puts "The #{COMMON_CONFIGURATION_FILE} file cannot be read"
        return false
      end
      if not File.readable?(CLUSTER_CONFIGURATION_FILE) then
        puts "The #{CLUSTER_CONFIGURATION_FILE} file cannot be read"
        return false
      end
      #configuration node file
      if not File.readable?(NODES_FILE) then
        puts "The #{NODES_FILE} file cannot be read"
        return false
      end
      if not File.readable?(VERSION_FILE) then
        puts "The #{VERSION_FILE} file cannot be read"
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
    def load_common_config_file
      IO.readlines(COMMON_CONFIGURATION_FILE).each { |line|
        if not (/^#/ =~ line) then #we ignore commented lines
          if /(.+)\ \=\ (.+)/ =~ line then
            content = Regexp.last_match
            attr = content[1]
            val = content[2].strip
            case attr
            when "verbose_level"
              if val =~ /\A[0-4]\Z/ then
                @common.verbose_level = val.to_i
              else
                puts "Invalid verbose level"
                return false
              end
            when "tftp_repository"
              @common.tftp_repository = val
            when "tftp_images_path"
              @common.tftp_images_path = val
            when "tftp_cfg"
              @common.tftp_cfg = val
            when "tftp_images_max_size"
              @common.tftp_images_max_size = val.to_i
            when "db_kind"
              @common.db_kind = val
            when "deploy_db_host"
              @common.deploy_db_host = val
            when "deploy_db_name"
              @common.deploy_db_name = val
            when "deploy_db_login"
              @common.deploy_db_login = val
            when "deploy_db_passwd"
              @common.deploy_db_passwd = val
            when "rights_kind"
              @common.rights_kind = val
            when "taktuk_connector"
              @common.taktuk_connector = val
            when "taktuk_tree_arity"
              @common.taktuk_tree_arity = val.to_i
            when "taktuk_auto_propagate"
              if val =~ /\A(true|false)\Z/
                @common.taktuk_auto_propagate = (val == "true")
              else
                puts "Invalid value for the taktuk_auto_propagate field"
                return false
              end
            when "tarball_dest_dir"
              @common.tarball_dest_dir = val
            when "kadeploy_server"
              @common.kadeploy_server = val
            when "kadeploy_server_port"
              @common.kadeploy_server_port = val.to_i
            when "kadeploy_tcp_buffer_size"
              @common.kadeploy_tcp_buffer_size = val.to_i
            when "kadeploy_cache_dir"
              if (val == "no_cache") then
                @common.kadeploy_disable_cache = true
                #We set a default value since it is used by the Bittorrent implemantation
                @common.kadeploy_cache_dir = "/tmp"
              else
                @common.kadeploy_cache_dir = val
              end
            when "kadeploy_cache_size"
              @common.kadeploy_cache_size = val.to_i
            when "max_preinstall_size"
              @common.max_preinstall_size = val.to_i
            when "max_postinstall_size"
              @common.max_postinstall_size = val.to_i 
            when "ssh_port"
              if val =~ /\A\d+\Z/ then
                @common.ssh_port = val
              else
                puts "Invalid value for SSH port"
                return false
              end
            when "test_deploy_env_port"
              if val =~ /\A\d+\Z/ then
                @common.test_deploy_env_port = val
              else
                puts "Invalid value for the test_deploy_env_port field"
                return false
              end
            when "environment_extraction_dir"
              @common.environment_extraction_dir = val
            when "log_to_file"
              @common.log_to_file = val
              if File.exist?(@common.log_to_file) then
                if not File.file?(@common.log_to_file) then
                  puts "The log file #{@common.log_to_file} is not a regular file"
                  return false
                else
                  if not File.writable?(@common.log_to_file) then
                    puts "The log file #{@common.log_to_file} is not writable"
                    return false
                  end
                end
              else
                begin
                  FileUtils.touch(@common.log_to_file)
                rescue
                  puts "Cannot write the log file: #{@common.log_to_file}"
                  return false
                end
              end
            when "log_to_syslog"
              if val =~ /\A(true|false)\Z/ then
                @common.log_to_syslog = (val == "true")
              else
                puts "Invalid value for the log_to_syslog field"
                return false
              end
            when "log_to_db"
              if val =~ /\A(true|false)\Z/ then
                @common.log_to_db = (val == "true")
              else
                puts "Invalid value for the log_to_db field"
                return false
              end
            when "dbg_to_syslog"
              if val =~ /\A(true|false)\Z/ then
                @common.dbg_to_syslog = (val == "true")
              else
                puts "Invalid value for the dbg_to_syslog field"
                return false
              end
            when "dbg_to_syslog_level"
              if val =~ /\A[0-4]\Z/ then
                @common.dbg_to_syslog_level = val.to_i
              else
                puts "Invalid value for the dbg_to_syslog_level field"
                return false
              end
            when "reboot_window"
              if val =~ /\A\d+\Z/ then
                @common.reboot_window = val.to_i
              else
                puts "Invalid value for the reboot_window field"
                return false
              end
            when "reboot_window_sleep_time"
              if val =~ /\A\d+\Z/ then
                @common.reboot_window_sleep_time = val.to_i
              else
                puts "Invalid value for the reboot_window_sleep_time field"
                return false
              end
            when "nodes_check_window"
              if val =~ /\A\d+\Z/ then
                @common.nodes_check_window = val.to_i
              else
                puts "Invalid value for the nodes_check_window field"
                return false
              end
            when "bootloader"
              if val =~ /\A(chainload_pxe|pure_pxe)\Z/
                @common.bootloader = val
              else
                puts "#{val} is an invalid entry for bootloader, only the chainload_pxe and pure_pxe values are allowed."
                return false
              end
            when "purge_deployment_timer"
              if val =~ /\A\d+\Z/ then
                @common.purge_deployment_timer = val.to_i
              else
                puts "Invalid value for the purge_deployment_timer field"
                return false
              end
            when "rambin_path"
              @common.rambin_path = val
            when "mkfs_options"
              #mkfs_options = type1@opts|type2@opts....
              if val =~ /\A\w+@.+(|\w+|.+)*\Z/ then
                @common.mkfs_options = Hash.new
                val.split("|").each { |entry|
                  fstype = entry.split("@")[0]
                  opts = entry.split("@")[1]
                  @common.mkfs_options[fstype] = opts
                }
              else
                puts "Wrong entry for mkfs_options"
                return false
              end
            when "demolishing_env_threshold"
              if val =~ /\A\d+\Z/ then
                @common.demolishing_env_threshold = val.to_i
              else
                puts "Invalid value for the demolishing_env_threshold field"
                return false
              end
            when "demolishing_env_auto_tag"
              if val =~ /\A(true|false)\Z/ then
                @common.demolishing_env_auto_tag = (val == "true")
              else
                puts "Invalid value for the demolishing_env_auto_tag field"
                return false
              end
            when "bt_tracker_ip"
              if val =~ /\A\d{1,3}.\d{1,3}.\d{1,3}.\d{1,3}\Z/ then
                @common.bt_tracker_ip = val
              else
                puts "Invalid value for the bt_tracker_ip field"
                return false
              end
            when "bt_download_timeout"
              if val =~ /\A\d+\Z/ then
                @common.bt_download_timeout = val.to_i
              else
                puts "Invalid value for the bt_download_timeout field"
                return false
              end
            when "almighty_env_users"
              if val =~ /\A\w+(,\w+)*\Z/ then
                @common.almighty_env_users = val.split(",")
              end
            when "async_end_of_deployment_hook"
              @common.async_end_of_deployment_hook = val
            when "async_end_of_reboot_hook"
              @common.async_end_of_reboot_hook = val
            when "async_end_of_power_hook"
              @common.async_end_of_power_hook = val
            when "vlan_hostname_suffix"
              @common.vlan_hostname_suffix = val
            when "set_vlan_cmd"
              @common.set_vlan_cmd = val
            end
          end
        end
      }
      if not @common.check_all_fields_filled() then
        return false
      end
      #tftp directory
      if not File.exist?(@common.tftp_repository) then
        puts "The #{@common.tftp_repository} directory does not exist"
        return false
      end
      if ((not @common.kadeploy_disable_cache) && (not File.exist?(@common.kadeploy_cache_dir))) then
        puts "The #{@common.kadeploy_cache_dir} directory does not exist, let's create it"
        res = Dir.mkdir(@common.kadeploy_cache_dir, 0700) rescue false
        if res.kind_of? FalseClass then
          puts "The directory cannot be created"
          return false
        end
      else
        if (not File.stat(@common.kadeploy_cache_dir).writable?) then
          puts "The #{@common.kadeploy_cache_dir} directory is not writable"
          return false
        end
      end
      #tftp image directory
      if not File.exist?(File.join(@common.tftp_repository, @common.tftp_images_path)) then
        puts "The #{File.join(@common.tftp_repository, @common.tftp_images_path)} directory does not exist"
        return false
      end
      #tftp config directory
      if not File.exist?(File.join(@common.tftp_repository, @common.tftp_cfg)) then
        puts "The #{File.join(@common.tftp_repository, @common.tftp_cfg)} directory does not exist"
        return false
      end
      return true
    end

    # Load the client configuration file
    #
    # Arguments
    # * nothing
    # Output
    # * return an Hash that contains the servers info
    def Config.load_client_config_file
      servers = Hash.new
      IO.readlines(CLIENT_CONFIGURATION_FILE).each { |line|
        if not (/^#/ =~ line) then #we ignore commented lines
          if /\A(default)\ \=\ (\w+)\Z/ =~ line then
            content = Regexp.last_match
            shortcut = content[2]
            servers["default"] = shortcut
          end
          if /\A(\w+)\ \=\ ([\w.-]+):(\d+)\Z/ =~ line then
            content = Regexp.last_match
            shortcut = content[1]
            host = content[2]
            port = content[3]
            servers[shortcut] = [host, port]
          end
        end
      }
      return servers
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
          @cluster_specific[cluster].group_of_nodes[command].push(line.chomp.split(","))
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
    def load_cluster_specific_config_files
      IO.readlines(CLUSTER_CONFIGURATION_FILE).each { |c|
        cluster = c.chomp
        if (not (/^#/ =~ cluster)) && (not (/\A\s*\Z/ =~ cluster)) then
          cluster_file = SPECIFIC_CONFIGURATION_FILE_PREFIX + cluster
          if not File.readable?(cluster_file) then
            puts "The #{cluster_file} file cannot be read"
            return false
          end
          partition_file = PARTITION_FILE_PREFIX + cluster
          if not File.readable?(partition_file) then
            puts "The #{partition_file} file cannot be read"
            return false
          end
          @cluster_specific[cluster] = ClusterSpecificConfig.new
          @cluster_specific[cluster].partition_file = partition_file
          IO.readlines(cluster_file).each { |line|
            if not (/^#/ =~ line) then #we ignore commented lines
              if /(.+)\ \=\ (.+)/ =~ line then
                content = Regexp.last_match
                attr = content[1]
                val = content[2].strip
                case attr
                when "deploy_kernel"
                  @cluster_specific[cluster].deploy_kernel = val
                when "deploy_initrd"
                  @cluster_specific[cluster].deploy_initrd = val
                when "block_device"
                  @cluster_specific[cluster].block_device = val
                when "deploy_part"
                  @cluster_specific[cluster].deploy_part = val
                when "prod_part"
                  @cluster_specific[cluster].prod_part = val
                when "tmp_part"
                  @cluster_specific[cluster].tmp_part = val
                when "swap_part"
                  @cluster_specific[cluster].swap_part = val
                when "workflow_steps"
                  @cluster_specific[cluster].workflow_steps = val
                when "timeout_reboot_classical"
                  n = 1
                  begin
                    timeout = eval(val).to_i
                    @cluster_specific[cluster].timeout_reboot_classical = val
                  rescue
                    puts "Invalid value for the timeout_reboot_classical field in the #{cluster} config file"
                    return false
                  end
                when "timeout_reboot_kexec"
                  n = 1
                  begin
                    timeout = eval(val).to_i
                    @cluster_specific[cluster].timeout_reboot_kexec = val
                  rescue
                    puts "Invalid value for the timeout_reboot_kexec field in the #{cluster} config file"
                    return false
                  end
                when "cmd_soft_reboot"
                  tmp = val.split(",")
                  @cluster_specific[cluster].cmd_soft_reboot = tmp[0]
                  (return false if not add_group_of_nodes("soft_reboot", tmp[1], cluster)) if (tmp[1] != nil)
                when "cmd_hard_reboot"
                  tmp = val.split(",")
                  @cluster_specific[cluster].cmd_hard_reboot = tmp[0]
                  (return false if not add_group_of_nodes("hard_reboot", tmp[1], cluster)) if (tmp[1] != nil)
                when "cmd_very_hard_reboot"
                  tmp = val.split(",")
                  @cluster_specific[cluster].cmd_very_hard_reboot = tmp[0]
                  (return false if not add_group_of_nodes("very_hard_reboot", tmp[1], cluster)) if (tmp[1] != nil)
                when "cmd_console"
                  @cluster_specific[cluster].cmd_console = val
                when "cmd_soft_power_off"
                  tmp = val.split(",")
                  @cluster_specific[cluster].cmd_soft_power_off = tmp[0]
                  (return false if not add_group_of_nodes("soft_power_off", tmp[1], cluster)) if (tmp[1] != nil)
                  when "cmd_hard_power_off"
                  tmp = val.split(",")
                  @cluster_specific[cluster].cmd_hard_power_off = tmp[0]
                  (return false if not add_group_of_nodes("hard_power_off", tmp[1], cluster)) if (tmp[1] != nil)
                when "cmd_very_hard_power_off"
                  tmp = val.split(",")
                  @cluster_specific[cluster].cmd_very_hard_power_off = tmp[0]
                  (return false if not add_group_of_nodes("very_hard_power_off", tmp[1], cluster)) if (tmp[1] != nil)
                when "cmd_soft_power_on"
                  tmp = val.split(",")
                  @cluster_specific[cluster].cmd_soft_power_on = tmp[0]
                  (return false if not add_group_of_nodes("soft_power_on", tmp[1], cluster)) if (tmp[1] != nil)
                when "cmd_hard_power_on"
                  tmp = val.split(",")
                  @cluster_specific[cluster].cmd_hard_power_on = tmp[0]
                  (return false if not add_group_of_nodes("hard_power_on", tmp[1], cluster)) if (tmp[1] != nil)
                when "cmd_very_hard_power_on"
                  tmp = val.split(",")
                  @cluster_specific[cluster].cmd_very_hard_power_on = tmp[0]
                  (return false if not add_group_of_nodes("very_hard_power_on", tmp[1], cluster)) if (tmp[1] != nil)
                when "cmd_power_status"
                  @cluster_specific[cluster].cmd_power_status = val
                when "drivers"
                  val.split(",").each { |driver|
                    @cluster_specific[cluster].drivers = Array.new if (@cluster_specific[cluster].drivers == nil)
                    @cluster_specific[cluster].drivers.push(driver)
                  }
                when "pxe_header"
                  @cluster_specific[cluster].pxe_header = val.gsub("\\n","\n")
                when "kernel_params"
                  @cluster_specific[cluster].kernel_params = val
                when "nfsroot_kernel"
                  @cluster_specific[cluster].nfsroot_kernel = val
                when "nfsroot_params"
                  @cluster_specific[cluster].nfsroot_params = val
                when "admin_pre_install"
                  #filename|kind|script,filename|kind|script,...
                  if val =~ /\A.+\|(tgz|tbz2)\|.+(,.+\|(tgz|tbz2)\|.+)*\Z/ then
                    @cluster_specific[cluster].admin_pre_install = Array.new
                    val.split(",").each { |tmp|
                      val = tmp.split("|")
                      entry = Hash.new
                      entry["file"] = val[0]
                      entry["kind"] = val[1]
                      entry["script"] = val[2]
                      @cluster_specific[cluster].admin_pre_install.push(entry)
                    }
                  elsif val =~ /\A(no_pre_install)\Z/ then
                    @cluster_specific[cluster].admin_pre_install = nil
                  else
                    puts "Invalid value for the admin_pre_install field in the #{cluster} config file"
                    return false
                  end
                when "admin_post_install"
                  #filename|tgz|script,filename|tgz|script,...
                  if val =~ /\A.+\|(tgz|tbz2)\|.+(,.+\|(tgz|tbz2)\|.+)*\Z/ then
                    @cluster_specific[cluster].admin_post_install = Array.new
                    val.split(",").each { |tmp|
                      val = tmp.split("|")
                      entry = Hash.new
                      entry["file"] = val[0]
                      entry["kind"] = val[1]
                      entry["script"] = val[2]
                      @cluster_specific[cluster].admin_post_install.push(entry)
                    }
                  elsif val =~ /\A(no_post_install)\Z/ then
                    @cluster_specific[cluster].admin_post_install = nil
                  else
                    puts "Invalid value for the admin_post_install field in the #{cluster} config file"
                    return false
                  end
                when "macrostep"
                  macrostep_name = val.split("|")[0]
                  microstep_list = val.split("|")[1]
                  tmp = Array.new
                  microstep_list.split(",").each { |instance_infos|
                    instance_name = instance_infos.split(":")[0]
                    instance_max_retries = instance_infos.split(":")[1].to_i
                    instance_timeout = instance_infos.split(":")[2].to_i
                    tmp.push([instance_name, instance_max_retries, instance_timeout])
                  }
                  @cluster_specific[cluster].workflow_steps.push(MacroStep.new(macrostep_name, tmp))
                when "partition_creation_kind"
                  if val =~ /\A(fdisk|parted)\Z/ then
                    @cluster_specific[cluster].partition_creation_kind = val
                  else
                    puts "Invalid value for the partition_creation_kind in the #{cluster} config file. Expected values are fdisk or parted"
                    return false
                  end
                when "use_ip_to_deploy"
                  if val =~ /\A(true|false)\Z/ then
                    @cluster_specific[cluster].use_ip_to_deploy = (val == "true")
                  else
                    puts "Invalid value for the use_ip_to_deploy field in the #{cluster} config file. Expected values are true or false"
                    return false
                  end
                end
              end
            end
          }
          if @cluster_specific[cluster].check_all_fields_filled(cluster) == false then
            return false
          end
          #admin_pre_install file
          if (cluster_specific[cluster].admin_pre_install != nil) then
            @cluster_specific[cluster].admin_pre_install.each { |entry|
              if not File.exist?(entry["file"]) then
                puts "The admin_pre_install file #{entry["file"]} does not exist"
                return false
              else
                if ((entry["kind"] != "tgz") && (entry["kind"] != "tbz2")) then
                  puts "Only tgz and tbz2 file kinds are allowed for preinstall files"
                  return false
                end
              end
            }
          end
          #admin_post_install file
          if (@cluster_specific[cluster].admin_post_install != nil) then
            @cluster_specific[cluster].admin_post_install.each { |entry|
              if not File.exist?(entry["file"]) then
                puts "The admin_post_install file #{entry["file"]} does not exist"
                return false
              else
                if ((entry["kind"] != "tgz") && (entry["kind"] != "tbz2")) then
                  puts "Only tgz and tbz2 file kinds are allowed for postinstall files"
                  return false
                end
              end
            }
          end          
        end
      }
      return true
    end

    # Load the nodes configuration file
    #
    # Arguments
    # * nothing
    # Output
    # * return true in case of success, false otherwise
    def load_nodes_config_file
      IO.readlines(NODES_FILE).each { |line|
        if /\A([a-zA-Z]+[-\w.]*)\ (\d{1,3}.\d{1,3}.\d{1,3}.\d{1,3})\ ([\w.-]+)\Z/ =~ line then
          content = Regexp.last_match
          host = content[1]
          ip = content[2]
          cluster = content[3]
          if @cluster_specific.has_key?(cluster) then
            @common.nodes_desc.push(Nodes::Node.new(host, ip, cluster, generate_commands(host, cluster)))
          else
            puts "The cluster #{cluster} has not been defined in #{CLUSTER_CONFIGURATION_FILE}"
          end
        end
        if /\A([A-Za-z0-9\.\-]+\[[\d{1,3}\-,\d{1,3}]+\][A-Za-z0-9\.\-]*)\ (\d{1,3}\.\d{1,3}\.\d{1,3}\.\[[\d{1,3}\-,\d{1,3}]*\])\ ([A-Za-z0-9\.\-]+)\Z/ =~ line then
          content = Regexp.last_match
          hostnames = content[1]
          ips = content[2]
          cluster = content[3]
          hostnames_list = Nodes::NodeSet::nodes_list_expand(hostnames)
          ips_list = Nodes::NodeSet::nodes_list_expand(ips)
          if (hostnames_list.to_a.length == ips_list.to_a.length) then
            for i in (0 ... hostnames_list.to_a.length)
              host = hostnames_list[i] 
              ip = ips_list[i] 
              @common.nodes_desc.push(Nodes::Node.new(host, ip, cluster, generate_commands(host, cluster)))
            end
          else
            puts line
            puts "The number of hostnames and IP addresses are incoherent in the #{NODES_FILE} file"
            return false
          end
        end
      }
      if @common.nodes_desc.empty? then
        puts "The nodes list is empty"
        return false
      else
        return true
      end
    end

    # Eventually load some specific commands for specific nodes that override generic commands
    #
    # Arguments
    # * nothing
    # Output
    # * return true in case of success, false otherwise
    def load_commands
      commands_file = COMMANDS_FILE
      if File.readable?(commands_file) then
        IO.readlines(commands_file).each { |line|
          if not ((/^#/ =~ line) || (/^$/ =~ line)) then #we ignore commented lines and empty lines
            if /(.+)\|(.+)\|(.+)/ =~ line then
              content = Regexp.last_match
              node = @common.nodes_desc.get_node_by_host(content[1])
              if (node != nil) then
                kind = content[2]
                val = content[3].strip
                if (node.cmd.instance_variable_defined?("@#{kind}")) then
                  node.cmd.instance_variable_set("@#{kind}", val)
                else
                  puts "Unknown command kind: #{content[2]}"
                  return false
                end
              else
                puts "The node #{content[1]} does not exist"
                return false
              end
            else
              puts "Wrong format for commands file: #{line}"
              return false
            end
          end
        }
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
      @common.version = line[0].chomp
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
        puts "Missing specific config file for the cluster #{cluster}"
        raise
      end
    end


##################################
#       Kadeploy specific        #
##################################

    # Load the command-line options of kadeploy
    #
    # Arguments
    # * exec_specific: open struct that contains some execution specific stuffs (modified)
    # Output
    # * return true in case of success, false otherwise
    def Config.load_kadeploy_cmdline_options(exec_specific)
      opts = OptionParser::new do |opt|
        opt.summary_indent = "  "
        opt.summary_width = 32
        opt.banner = "Usage: kadeploy3 [options]"
        opt.separator "Contact: #{CONTACT_EMAIL}"
        opt.separator ""
        opt.separator "General options:"
        opt.on("-a", "--env-file ENVFILE", "File containing the environment description") { |f|
          if not (f =~ /^http[s]?:\/\//) then
            if not File.readable?(f) then
              error("The file #{f} does not exist or is not readable")
              return false
            else
              IO.readlines(f).each { |line|
                exec_specific.load_env_content += line
              }
            end
          end
          exec_specific.load_env_kind = "file"
          exec_specific.load_env_arg = f
        }
        opt.on("-b", "--block-device BLOCKDEVICE", "Specify the block device to use") { |b|
          if /\A[\w\/]+\Z/ =~ b then
            exec_specific.block_device = b
          else
            error("Invalid block device")
            return false
          end
        }
        opt.on("-d", "--debug-mode", "Activate the debug mode") {
          exec_specific.debug = true
        }
        opt.on("-e", "--env-name ENVNAME", "Name of the recorded environment to deploy") { |n|
          exec_specific.load_env_kind = "db"
          exec_specific.load_env_arg = n
        }
        opt.on("-f", "--file MACHINELIST", "Files containing list of nodes (- means stdin)")  { |f|
          if (f == "-") then
            STDIN.read.split("\n").sort.uniq.each { |hostname|
              if not (/\A[A-Za-z0-9\.\-\[\]\,]+\Z/ =~ hostname) then
                error("Invalid hostname: #{hostname}")
                return false
              else
                exec_specific.node_array.push(hostname.chomp)
              end
            }
          else
            if not File.readable?(f) then
              error("The file #{f} cannot be read")
              return false
            else
              IO.readlines(f).sort.uniq.each { |hostname|
                if not (/\A[A-Za-z0-9\.\-\[\]\,]+\Z/ =~ hostname) then
                  error("Invalid hostname: #{hostname}")
                  return false
                else
                  exec_specific.node_array.push(hostname.chomp)
                end
              }
            end
          end
        }
        opt.on("-k", "--key [FILE]", "Public key to copy in the root's authorized_keys, if no argument is specified, use the authorized_keys") { |f|
          if (f != nil) then
            if (f =~ /^http[s]?:\/\//) then
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
        opt.on("-m", "--machine MACHINE", "Node to run on") { |hostname|
          if not (/\A[A-Za-z0-9\.\-\[\]\,]+\Z/ =~ hostname) then
            error("Invalid hostname: #{hostname}")
            return false
          else
            exec_specific.node_array.push(hostname.chomp)
          end
        }
        opt.on("--multi-server", "Activate the multi-server mode") {
          exec_specific.multi_server = true
        }
        opt.on("-n", "--output-ko-nodes FILENAME", "File that will contain the nodes not correctly deployed")  { |f|
          exec_specific.nodes_ko_file = f
        }
        opt.on("-o", "--output-ok-nodes FILENAME", "File that will contain the nodes correctly deployed")  { |f|
          exec_specific.nodes_ok_file = f
        }
        opt.on("-p", "--partition-number NUMBER", "Specify the partition number to use") { |p|
            exec_specific.deploy_part = p
        }
        opt.on("-r", "--reformat-tmp FSTYPE", "Reformat the /tmp partition with the given filesystem type (ext[234] are allowed)") { |t|
          if not (/\A(ext2|ext3|ext4)\Z/ =~ t) then
            error("Invalid FSTYPE, only ext2, ext3 and ext4 are allowed")
            return false
          end
          exec_specific.reformat_tmp = true
          exec_specific.reformat_tmp_fstype = t
        }
        opt.on("-s", "--script FILE", "Execute a script at the end of the deployment") { |f|
          if not File.readable?(f) then
            error("The file #{f} cannot be read")
            return false
          else
            if not File.stat(f).executable? then
              error("The file #{f} must be executable to be run at the end of the deployment")
              return false
            else
              exec_specific.script = File.expand_path(f)
            end
          end
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
              if (not (/^#/ =~ l)) and (not (/^$/ =~ l)) then #we ignore commented and empty lines
                content = l.split(",")
                exec_specific.pxe_profile_singularities[content[0]] = content[1].strip
              end
            }
          end
        }
        opt.on("-x", "--upload-pxe-files FILES", "Upload a list of files (file1,file2,file3) to the \"tftp_images_path\" directory. Those files will be prefixed with \"pxe-$username-\" ") { |l|
          l.split(",").each { |file|
            if (file =~ /^http[s]?:\/\//) then
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
        opt.on("--env-version NUMBER", "Number of version of the environment to deploy") { |n|
          if /\A\d+\Z/ =~ n then
            exec_specific.env_version = n
          else
            error("Invalid version number")
            return false
          end
        }
        opt.on("--server STRING", "Specify the Kadeploy server to use") { |s|
          exec_specific.chosen_server = s
        } 
        opt.on("-V", "--verbose-level VALUE", "Verbose level between 0 to 4") { |d|
          if d =~ /\A[0-4]\Z/ then
            exec_specific.verbose_level = d.to_i
          else
            error("Invalid verbose level")
            return false
          end
        }
        opt.separator "Advanced options:"
        opt.on("--write-workflow-id FILE", "Write the workflow id in a file") { |file|
          exec_specific.write_workflow_id = file
        }
        opt.on("--ignore-nodes-deploying", "Allow to deploy even on the nodes tagged as \"currently deploying\" (use this only if you know what you do)") {
          exec_specific.ignore_nodes_deploying = true
        }        
        opt.on("--disable-bootloader-install", "Disable the automatic installation of a bootloader for a Linux based environnment") {
          exec_specific.disable_bootloader_install = true
        }
        opt.on("--disable-disk-partitioning", "Disable the disk partitioning") {
          exec_specific.disable_disk_partitioning = true
        }
        opt.on("--breakpoint MICROSTEP", "Set a breakpoint just before lauching the given micro-step, the syntax is macrostep:microstep (use this only if you know what you do)") { |m|
          if (m =~ /\A[a-zA-Z0-9_]+:[a-zA-Z0-9_]+\Z/)
            exec_specific.breakpoint_on_microstep = m
          else
            error("The value #{m} for the breakpoint entry is invalid")
            return false
          end
        }
        opt.on("--set-custom-operations FILE", "Add some custom operations defined in a file") { |file|
          exec_specific.custom_operations_file = file
          if not File.readable?(file) then
            error("The file #{file} cannot be read")
            return false
          else
            exec_specific.custom_operations = Hash.new
            #example of line: macro_step,microstep@cmd1%arg%dir,cmd2%arg%dir,...,cmdN%arg%dir
            IO.readlines(file).each { |line|
              if (line =~ /\A\w+,\w+@\w+%.+%.+(,\w+%.+%.+)*\Z/) then
                step = line.split("@")[0]
                cmds = line.split("@")[1]
                macro_step = step.split(",")[0]
                micro_step = step.split(",")[1]
                exec_specific.custom_operations[macro_step] = Hash.new if (not exec_specific.custom_operations.has_key?(macro_step))
                exec_specific.custom_operations[macro_step][micro_step] = Array.new if (not exec_specific.custom_operations[macro_step].has_key?(micro_step))
                cmds.split(",").each { |cmd|
                  entry = cmd.split("%")
                  exec_specific.custom_operations[macro_step][micro_step].push(entry)
                }
              end
            }
          end
        }
        opt.on("--reboot-classical-timeout V", "Overload the default timeout for classical reboots") { |t|
          if (t =~ /\A\d+\Z/) then
            exec_specific.reboot_classical_timeout = t
          else
            error("A number is required for the reboot classical timeout")
          end
        }
        opt.on("--reboot-kexec-timeout V", "Overload the default timeout for kexec reboots") { |t|
          if (t =~ /\A\d+\Z/) then
            exec_specific.reboot_kexec_timeout = t
          else
            error("A number is required for the reboot kexec timeout")
          end
        }
        opt.on("--force-steps STRING", "Undocumented, for administration purpose only") { |s|
          s.split("&").each { |macrostep|
            macrostep_name = macrostep.split("|")[0]
            microstep_list = macrostep.split("|")[1]
            tmp = Array.new
            microstep_list.split(",").each { |instance_infos|
              instance_name = instance_infos.split(":")[0]
              instance_max_retries = instance_infos.split(":")[1].to_i
              instance_timeout = instance_infos.split(":")[2].to_i
              tmp.push([instance_name, instance_max_retries, instance_timeout])
            }
            exec_specific.steps.push(MacroStep.new(macrostep_name, tmp))
          }
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

      if not exec_specific.get_version then
        if exec_specific.node_array.empty? then
          error("You must specify some nodes to deploy")
          return false
        end
        if (exec_specific.nodes_ok_file != "") && (exec_specific.nodes_ok_file == exec_specific.nodes_ko_file) then
          error("The files used for the output of the OK and the KO nodes must not be the same")
          return false
        end
      end
      return true
    end

    # Add a node involved in the deployment to the exec_specific.node_set
    #
    # Arguments
    # * hostname: hostname of the node
    # * nodes_desc: set of nodes read from the configuration file
    # * exec_specific: open struct that contains some execution specific stuffs (modified)
    # Output
    # * return true if the node exists in the Kadeploy configuration, false otherwise
    def add_to_node_set(hostname, exec_specific)
      if /\A[A-Za-z\.\-]+[0-9]*\[[\d{1,3}\-,\d{1,3}]+\][A-Za-z0-9\.\-]*\Z/ =~ hostname
        hostnames = Nodes::NodeSet::nodes_list_expand("#{hostname}") 
      else
        hostnames = [hostname]
      end
      hostnames.each{|hostname|
        n = @common.nodes_desc.get_node_by_host(hostname)
        if (n != nil) then
          exec_specific.node_set.push(n)
        else
          return false
        end
      }
      return true
    end
    
 
##################################
#         Kaenv specific         #
##################################

    # Load the kaenv specific stuffs
    #
    # Arguments
    # * nothing
    # Output
    # * return true in case of success, false otherwise
    def Config.load_kaenv_exec_specific()
      exec_specific = OpenStruct.new
      exec_specific.environment = EnvironmentManagement::Environment.new
      exec_specific.operation = String.new
      exec_specific.file = String.new
      exec_specific.file_content = String.new
      exec_specific.env_name = String.new
      exec_specific.user = USER #By default, we use the current user
      exec_specific.true_user = USER #By default, we use the current user
      exec_specific.visibility_tag = String.new
      exec_specific.show_all_version = false
      exec_specific.version = String.new
      exec_specific.files_to_move = Array.new
      exec_specific.get_version = false
      exec_specific.chosen_server = String.new
      exec_specific.servers = Config.load_client_config_file
      exec_specific.kadeploy_server = String.new
      exec_specific.kadeploy_server_port = String.new

      if Config.load_kaenv_cmdline_options(exec_specific) then
        return exec_specific
      else
        return nil
      end
    end

    # Load the command-line options of kaenv
    #
    # Arguments
    # * nothing
    # Output
    # * return true in case of success, false otherwise
    def Config.load_kaenv_cmdline_options(exec_specific)
      opts = OptionParser::new do |opt|
        opt.summary_indent = "  "
        opt.summary_width = 38
        opt.banner = "Usage: kaenv3 [options]"
        opt.separator "Contact: #{CONTACT_EMAIL}"
        opt.separator ""
        opt.separator "General options:"
        opt.on("-a", "--add ENVFILE", "Add an environment") { |f|
          if (not (f =~ /^http[s]?:\/\//)) && (not File.readable?(f)) then
            error("The file #{f} cannot be read")
            return false
          else
            IO.readlines(f).each { |line|
              exec_specific.file_content += line
            }
          end
          exec_specific.file = f
          exec_specific.operation = "add"
        }
        opt.on("-d", "--delete ENVNAME", "Delete an environment") { |n|
          exec_specific.env_name = n
          exec_specific.operation = "delete"
        }  
        opt.on("-l", "--list", "List environments") {
          exec_specific.operation = "list"
        }
        opt.on("-m", "--files-to-move FILES", "Files to move (src1:dst1,src2:dst2,...)") { |f|
          if /\A.+:.+(,.+:.+)*\Z/ =~f then
            f.split(",").each { |src_dst|
              exec_specific.files_to_move.push({"src"=>src_dst.split(":")[0],"dest"=>src_dst.split(":")[1]})
            }
          else
            error("Invalid synthax for files to move")
            return false
          end
        }
        opt.on("-p", "--print ENVNAME", "Print an environment") { |n|
          exec_specific.env_name = n
          exec_specific.operation = "print"
        }        
        opt.on("-s", "--show-all-versions", "Show all versions of an environment") {
          exec_specific.show_all_version = true
        }
        opt.on("-t", "--visibility-tag TAG", "Set the visibility tag (private, shared, public)") { |v|
          if /\A(private|shared|public)\Z/ =~ v then
            exec_specific.visibility_tag = v
          else
            error("Invalid visibility tag")
          end
        }
        opt.on("-u", "--user USERNAME", "Specify the user") { |u|
          if /\A(\w+|\*)\Z/ =~ u then
            exec_specific.user = u
          else
            error("Invalid user name")
            return false
          end
        }
        opt.on("-v", "--version", "Get the version") {
          exec_specific.get_version = true
        }
        opt.on("--env-version NUMBER", "Specify the version") { |v|
          if /\A\d+\Z/ =~ v then
            exec_specific.version = v
          else
            error("Invalid version number")
            return false
          end
        }
        opt.on("--server STRING", "Specify the Kadeploy server to use") { |s|
          exec_specific.chosen_server = s
        } 
        opt.separator "Advanced options:"
        opt.on("--remove-demolishing-tag ENVNAME", "Remove demolishing tag on an environment") { |n|
          exec_specific.env_name = n
          exec_specific.operation = "remove-demolishing-tag"
        }
        opt.on("--set-visibility-tag ENVNAME", "Set the visibility tag on an environment") { |n|
          exec_specific.env_name = n
          exec_specific.operation = "set-visibility-tag"
        }
        opt.on("--update-tarball-md5 ENVNAME", "Update the MD5 of the environment tarball") { |n|
          exec_specific.env_name = n
          exec_specific.operation = "update-tarball-md5"
        }
        opt.on("--update-preinstall-md5 ENVNAME", "Update the MD5 of the environment preinstall") { |n|
          exec_specific.env_name = n
          exec_specific.operation = "update-preinstall-md5"
        }
        opt.on("--update-postinstalls-md5 ENVNAME", "Update the MD5 of the environment postinstalls") { |n|
          exec_specific.env_name = n
          exec_specific.operation = "update-postinstalls-md5"
        }
        opt.on("--move-files", "Move the files of the environments (for administrators only)") { |n|
          exec_specific.operation = "move-files"
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
      case exec_specific.operation 
      when "add"
        if (exec_specific.file == "") then
          error("You must choose a file that contains the environment description")
          return false
        end
      when "delete"
        if (exec_specific.env_name == "") then
          error("You must choose an environment")
          return false
        end
      when "list"
      when "print"
        if (exec_specific.env_name == "") then
          error("You must choose an environment")
          return false
        end
      when "update-tarball-md5"
        if (exec_specific.env_name == "") then
          error("You must choose an environment")
          return false
        end
      when "update-preinstall-md5"
        if (exec_specific.env_name == "") then
          error("You must choose an environment")
          return false
        end
      when "update-postinstalls-md5"
        if (exec_specific.env_name == "") then
          error("You must choose an environment")
          return false
        end
      when "remove-demolishing-tag"
        if (exec_specific.env_name == "") then
          error("You must choose an environment")
          return false
        end
      when "set-visibility-tag"
        if (exec_specific.env_name == "") then
          error("You must choose an environment")
          return false
        end
        if (exec_specific.version == "") then
          error("You must choose a version")
          return false
        end
        if (exec_specific.visibility_tag == "") then
          error("You must define the visibility value")
          return false          
        end
      when "move-files"
        if (exec_specific.files_to_move.empty?) then
          error("You must define some files to move")
          return false          
        end
      else
        error("You must choose an operation")
        return false
      end

      return true
    end


##################################
#       Karights specific        #
##################################

    # Load the karights specific stuffs
    #
    # Arguments
    # * nothing
    # Output
    # * return true in case of success, false otherwise
    def Config.load_karights_exec_specific()
      exec_specific = OpenStruct.new
      exec_specific.operation = String.new
      exec_specific.user = String.new
      exec_specific.part_list = Array.new
      exec_specific.node_list = Array.new
      exec_specific.true_user = USER
      exec_specific.overwrite_existing_rights = false
      exec_specific.get_version = false
      exec_specific.chosen_server = String.new
      exec_specific.servers = Config.load_client_config_file
      exec_specific.kadeploy_server = String.new
      exec_specific.kadeploy_server_port = String.new

      if Config.load_karights_cmdline_options(exec_specific) then
        return exec_specific
      else
        return nil
      end
    end

    # Load the command-line options of karights
    #
    # Arguments
    # * nothing
    # Output
    # * return true in case of success, false otherwise
    def Config.load_karights_cmdline_options(exec_specific)
      opts = OptionParser::new do |opt|
        opt.summary_indent = "  "
        opt.summary_width = 28
        opt.banner = "Usage: karights3 [options]"
        opt.separator "Contact: #{CONTACT_EMAIL}"
        opt.separator ""
        opt.separator "General options:"
        opt.on("-a", "--add", "Add some rights to a user") {
          exec_specific.operation = "add"
        }
        opt.on("-d", "--delete", "Delete some rights to a user") {
          exec_specific.operation = "delete"
        }
        opt.on("-f", "--file FILE", "Machine file (- means stdin)")  { |f|
          if (f == "-") then
            STDIN.read.split("\n").sort.uniq.each { |hostname|
              if not (/\A[A-Za-z0-9\.\-\[\]\,]+\Z/ =~ hostname) then
                error("Invalid hostname: #{hostname}")
                return false
              else
                exec_specific.node_list.push(hostname.chomp)
              end
            }
          else
            if not File.readable?(f) then
              error("The file #{f} cannot be read")
              return false
            else
              IO.readlines(f).sort.uniq.each { |hostname|
                if not (/\A[A-Za-z0-9\.\-\[\]\,]+\Z/ =~ hostname) then
                  error("Invalid hostname: #{hostname}")
                  return false
                end
                exec_specific.node_list.push(hostname.chomp)
              }
            end
          end
        }
        opt.on("-m", "--machine MACHINE", "Include the machine in the operation") { |m|
          if (not (/\A[A-Za-z0-9\[\]\.\-]+\Z/ =~ m)) and (m != "*") then
            error("Invalid hostname: #{m}")
            return false
          end
          exec_specific.node_list.push(m)
        }
        opt.on("-o", "--overwrite-rights", "Overwrite existing rights") {
          exec_specific.overwrite_existing_rights = true
        }        
        opt.on("-p", "--part PARTNAME", "Include the partition in the operation") { |p|
          exec_specific.part_list.push(p)
        }        
        opt.on("-s", "--show-rights", "Show the rights for a given user") {
          exec_specific.operation = "show"
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
      if (exec_specific.user == "") then
        error("You must choose a user")
        return false
      end

      if (exec_specific.operation == "add") || (exec_specific.operation  == "delete") then
        if (exec_specific.part_list.empty?) then
          error("You must specify at least one partition")
          return false
        end
        if (exec_specific.node_list.empty?) then
          error("You must specify at least one node")
          return false
        end
      end

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
        opt.on("-m", "--machine MACHINE", "Only print information about the given machines") { |m|
          if not (/\A[A-Za-z0-9\.\-\[\]\,]+\Z/ =~ m) then
            error("Invalid hostname: #{m}")
            return false
          end
          exec_specific.node_list.push(m)
        }
        opt.on("-s", "--step STEP", "Apply the retry filter on the given steps (1, 2 or 3)") { |s|
          exec_specific.steps.push(s) 
        }
        opt.on("-v", "--version", "Get the version") {
          exec_specific.get_version = true
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
        if not (/^\d{4}:\d{2}:\d{2}:\d{2}:\d{2}:\d{2}$/ === exec_specific.date_min) then
          error("The date #{exec_specific.date_min} is not correct")
          return false
        else
          str = exec_specific.date_min.split(":")
          exec_specific.date_min = Time.mktime(str[0], str[1], str[2], str[3], str[4], str[5]).to_i
        end
      end
      if (exec_specific.date_max != 0) then
        if not (/^\d{4}:\d{2}:\d{2}:\d{2}:\d{2}:\d{2}$/ === exec_specific.date_max) then
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
          if (f == "-") then
            STDIN.read.split("\n").sort.uniq.each { |hostname|
              if not (/\A[A-Za-z0-9\.\-\[\]\,]+\Z/ =~ hostname) then
                error("Invalid hostname: #{hostname}")
                return false
              else
                exec_specific.node_list.push(hostname.chomp)
              end
            }
          else
            if not File.readable?(f) then
              error("The file #{f} cannot be read")
              return false
            else
              IO.readlines(f).sort.uniq.each { |hostname|
                if not (/\A[A-Za-z0-9\.\-\[\]\,]+\Z/ =~ hostname) then
                  error("Invalid hostname: #{hostname}")
                  return false
                end
                exec_specific.node_list.push(hostname.chomp)
              }
            end
          end
        }
        opt.on("-m", "--machine MACHINE", "Only print information about the given machines") { |m|
          if not (/\A[A-Za-z0-9\.\-\[\]\,]+\Z/ =~ m) then
            error("Invalid hostname: #{m}")
            return false
          end
          exec_specific.node_list.push(m)
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
      exec_specific.verbose_level = String.new
      exec_specific.node_set = Nodes::NodeSet.new
      exec_specific.node_array = Array.new
      exec_specific.check_prod_env = false
      exec_specific.true_user = USER
      exec_specific.user = USER
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
        opt.on("-c", "--check-prod-env", "Check if the production environment has been detroyed") {
          exec_specific.check_prod_env = true
        }
        opt.on("-d", "--debug-mode", "Activate the debug mode") {
          exec_specific.debug = true
        }
        opt.on("-e", "--env-name ENVNAME", "Name of the recorded environment") { |e|
          exec_specific.env_arg = e
        }
        opt.on("-f", "--file MACHINELIST", "Files containing list of nodes (- means stdin)")  { |f|
          if (f == "-") then
            STDIN.read.split("\n").sort.uniq.each { |hostname|
              if not (/\A[A-Za-z0-9\.\-\[\]\,]+\Z/ =~ hostname) then
                error("Invalid hostname: #{hostname}")
                return false
              else
                exec_specific.node_array.push(hostname.chomp)
              end
            }
          else
            if not File.readable?(f) then
              error("The file #{f} cannot be read")
              return false
            else
              IO.readlines(f).sort.uniq.each { |hostname|
                if not (/\A[A-Za-z0-9\.\-\[\]\,]+\Z/ =~ hostname) then
                  error("Invalid hostname: #{hostname}")
                  return false
                else
                  exec_specific.node_array.push(hostname.chomp)
                end
              }
            end
          end
        }
        opt.on("-k", "--key [FILE]", "Public key to copy in the root's authorized_keys, if no argument is specified, use the authorized_keys") { |f|
          if (f != nil) then
            if (f =~ /^http[s]?:\/\//) then
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
          if not (/\A[A-Za-z0-9\.\-\[\]\,]+\Z/ =~ hostname) then
            error("Invalid hostname: #{hostname}")
            return false
          else
            exec_specific.node_array.push(hostname)
          end
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
              if (not (/^#/ =~ l)) and (not (/^$/ =~ l)) then #we ignore commented and empty lines
                content = l.split(",")
                exec_specific.pxe_profile_singularities[content[0]] = content[1].strip
              end
            }
          end
        }
        opt.on("-x", "--upload-pxe-files FILES", "Upload a list of files (file1,file2,file3) to the \"tftp_images_path\" directory. Those files will be prefixed with \"pxe-$username-\" ") { |l|
          l.split(",").each { |file|
            if (file =~ /^http[s]?:\/\//) then
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
        opt.on("-V", "--verbose-level VALUE", "Verbose level between 0 to 4") { |d|
          if d =~ /\A[0-4]\Z/ then
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
      if (exec_specific.verbose_level != "") && ((exec_specific.verbose_level > 4) || (exec_specific.verbose_level < 0)) then
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
        if exec_specific.check_prod_env then
          error("-c/--check-prod-env cannot be used with --no-wait")
          return false
        end
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
          if not (/\A[A-Za-z0-9\.\-]+\Z/ =~ hostname) then
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
      exec_specific.verbose_level = String.new
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
          if (f == "-") then
            STDIN.read.split("\n").sort.uniq.each { |hostname|
              if not (/\A[A-Za-z0-9\.\-\[\]\,]+\Z/ =~ hostname) then
                error("Invalid hostname: #{hostname}")
                return false
              else
                exec_specific.node_array.push(hostname.chomp)
              end
            }
          else
            if not File.readable?(f) then
              error("The file #{f} cannot be read")
              return false
            else
              IO.readlines(f).sort.uniq.each { |hostname|
                if not (/\A[A-Za-z0-9\.\-\[\]\,]+\Z/ =~ hostname) then
                  error("Invalid hostname: #{hostname}")
                  return false
                else
                  exec_specific.node_array.push(hostname.chomp)
                end
              }
            end
          end
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
          if not (/\A[A-Za-z0-9\.\-\[\]\,]+\Z/ =~ hostname) then
            error("Invalid hostname: #{hostname}")
            return false
          else
            exec_specific.node_array.push(hostname)
          end
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
        opt.on("-V", "--verbose-level VALUE", "Verbose level between 0 to 4") { |d|
          if d =~ /\A[0-4]\Z/ then
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
      if (exec_specific.verbose_level != "") && ((exec_specific.verbose_level > 4) || (exec_specific.verbose_level < 0)) then
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
    attr_accessor :verbose_level
    attr_accessor :tftp_repository
    attr_accessor :tftp_images_path
    attr_accessor :tftp_cfg
    attr_accessor :tftp_images_max_size
    attr_accessor :db_kind
    attr_accessor :deploy_db_host
    attr_accessor :deploy_db_name
    attr_accessor :deploy_db_login
    attr_accessor :deploy_db_passwd
    attr_accessor :rights_kind
    attr_accessor :nodes_desc     #information about all the nodes
    attr_accessor :taktuk_connector
    attr_accessor :taktuk_tree_arity
    attr_accessor :taktuk_auto_propagate
    attr_accessor :tarball_dest_dir
    attr_accessor :kadeploy_server
    attr_accessor :kadeploy_server_port
    attr_accessor :kadeploy_tcp_buffer_size
    attr_accessor :kadeploy_cache_dir
    attr_accessor :kadeploy_cache_size
    attr_accessor :max_preinstall_size
    attr_accessor :max_postinstall_size
    attr_accessor :kadeploy_disable_cache
    attr_accessor :ssh_port
    attr_accessor :test_deploy_env_port
    attr_accessor :environment_extraction_dir
    attr_accessor :log_to_file
    attr_accessor :log_to_syslog
    attr_accessor :log_to_db
    attr_accessor :dbg_to_syslog
    attr_accessor :dbg_to_syslog_level
    attr_accessor :reboot_window
    attr_accessor :reboot_window_sleep_time
    attr_accessor :nodes_check_window
    attr_accessor :bootloader
    attr_accessor :purge_deployment_timer
    attr_accessor :rambin_path
    attr_accessor :mkfs_options
    attr_accessor :demolishing_env_threshold
    attr_accessor :demolishing_env_auto_tag
    attr_accessor :bt_tracker_ip
    attr_accessor :bt_download_timeout
    attr_accessor :almighty_env_users
    attr_accessor :version
    attr_accessor :async_end_of_deployment_hook
    attr_accessor :async_end_of_reboot_hook
    attr_accessor :async_end_of_power_hook
    attr_accessor :vlan_hostname_suffix
    attr_accessor :set_vlan_cmd

    # Constructor of CommonConfig
    #
    # Arguments
    # * nothing
    # Output
    # * nothing
    def initialize
      @nodes_desc = Nodes::NodeSet.new
      @kadeploy_disable_cache = false
      @demolishing_env_auto_tag = false
      @log_to_file = ""
      @async_end_of_deployment_hook = ""
      @async_end_of_reboot_hook = ""
      @async_end_of_power_hook = ""
      @vlan_hostname_suffix = ""
      @set_vlan_cmd = ""
    end

    # Check if all the fields of the common configuration file are filled
    #
    # Arguments
    # * nothing
    # Output
    # * return true if all the fields are filled, false otherwise
    def check_all_fields_filled
      err_msg =  " field is missing in the common configuration file"
      self.instance_variables.each{|i|
        a = eval i
        puts "Warning: " + i + err_msg if (a == nil)
      }
      if ((@verbose_level == nil) || (@tftp_repository == nil) || (@tftp_images_path == nil) || (@tftp_cfg == nil) ||
          (@tftp_images_max_size == nil) || (@db_kind == nil) || (@deploy_db_host == nil) || (@deploy_db_name == nil) ||
          (@deploy_db_login == nil) || (@deploy_db_passwd == nil) || (@rights_kind == nil) || (@nodes_desc == nil) ||
          (@taktuk_connector == nil) ||
          (@taktuk_tree_arity == nil) || (@taktuk_auto_propagate == nil) || (@tarball_dest_dir == nil) ||
          (@kadeploy_server == nil) || (@kadeploy_server_port == nil) ||
          (@max_preinstall_size == nil) || (@max_postinstall_size == nil) ||
          (@kadeploy_tcp_buffer_size == nil) || (@kadeploy_cache_dir == nil) || (@kadeploy_cache_size == nil) ||
          (@ssh_port == nil) || (@test_deploy_env_port == nil) ||
          (@environment_extraction_dir == nil) || (@log_to_syslog == nil) || (@log_to_db == nil) ||
          (@dbg_to_syslog == nil) || (@dbg_to_syslog_level == nil) || (@reboot_window == nil) || 
          (@reboot_window_sleep_time == nil) || (@nodes_check_window == nil) ||
          (@bootloader == nil) || (@purge_deployment_timer == nil) || (@rambin_path == nil) ||
          (@mkfs_options == nil) || (@demolishing_env_threshold == nil) ||
          (@bt_tracker_ip == nil) || (@bt_download_timeout == nil) || (@almighty_env_users == nil)) then
        puts "Some mandatory fields are missing in the common configuration file"
        return false
      else
        return true
      end
    end
  end

  
  class ClusterSpecificConfig
    attr_accessor :deploy_kernel
    attr_accessor :deploy_initrd
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
    attr_accessor :partition_creation_kind
    attr_accessor :partition_file
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
      @deploy_kernel = nil
      @deploy_initrd = nil
      @block_device = nil
      @deploy_part = nil
      @prod_part = nil
      @tmp_part = nil
      @swap_part = nil
      @timeout_reboot_classical = nil
      @timeout_reboot_kexec = nil
      @cmd_soft_reboot = nil
      @cmd_hard_reboot = nil
      @cmd_very_hard_reboot = nil
      @cmd_console = nil
      @cmd_soft_power_on = nil
      @cmd_hard_power_on = nil
      @cmd_very_hard_power_on = nil
      @cmd_soft_power_off = nil
      @cmd_hard_power_off = nil
      @cmd_very_hard_power_off = nil
      @cmd_power_status = nil
      @group_of_nodes = Hash.new
      @drivers = nil
      @pxe_header = nil
      @kernel_params = nil
      @nfsroot_kernel = nil
      @nfsroot_params = nil
      @admin_pre_install = nil
      @admin_post_install = nil
      @partition_creation_kind = nil
      @partition_file = nil
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
      dest.workflow_steps = workflow_steps
      dest.deploy_kernel = @deploy_kernel.clone
      dest.deploy_initrd = @deploy_initrd.clone
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
      dest.pxe_header = @pxe_header.clone if (@pxe_header != nil)
      dest.kernel_params = @kernel_params.clone if (@kernel_params != nil)
      dest.nfsroot_kernel = @nfsroot_kernel.clone if (@nfsroot_kernel != nil)
      dest.nfsroot_params = @nfsroot_params.clone if (@nfsroot_params != nil)
      dest.admin_pre_install = @admin_pre_install.clone if (@admin_pre_install != nil)
      dest.admin_post_install = @admin_post_install.clone if (@admin_post_install != nil)
      dest.partition_creation_kind = @partition_creation_kind.clone
      dest.partition_file = @partition_file.clone
      dest.use_ip_to_deploy = @use_ip_to_deploy
    end
    
    # Duplicate a ClusterSpecificConfig instance
    #
    # Arguments
    # * dest: destination ClusterSpecificConfig instance
    # Output
    # * nothing      
    def duplicate_all(dest)
      dest.workflow_steps = Array.new
      @workflow_steps.each_index { |i|
        dest.workflow_steps[i] = @workflow_steps[i].clone
      }
      dest.deploy_kernel = @deploy_kernel.clone
      dest.deploy_initrd = @deploy_initrd.clone
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
      dest.pxe_header = @pxe_header.clone if (@pxe_header != nil)
      dest.kernel_params = @kernel_params.clone if (@kernel_params != nil)
      dest.nfsroot_kernel = @nfsroot_kernel.clone if (@nfsroot_kernel != nil)
      dest.nfsroot_params = @nfsroot_params.clone if (@nfsroot_params != nil)
      dest.admin_pre_install = @admin_pre_install.clone if (@admin_pre_install != nil)
      dest.admin_post_install = @admin_post_install.clone if (@admin_post_install != nil)
      dest.partition_creation_kind = @partition_creation_kind.clone
      dest.partition_file = @partition_file.clone
      dest.use_ip_to_deploy = @use_ip_to_deploy
    end

    # Check if all the fields of the common configuration file are filled
    #
    # Arguments
    # * cluster: cluster name
    # Output
    # * return true if all the fields are filled, false otherwise
    def check_all_fields_filled(cluster)
      err_msg =  " field is missing in the specific configuration file #{cluster}"
      self.instance_variables.each{|i|
        a = eval i
        puts "Warning: " + i + err_msg if (a == nil)
      }
      if ((@deploy_kernel == nil) || (@deploy_initrd == nil) || (@block_device == nil) || (@deploy_part == nil) || (@prod_part == nil) ||
          (@tmp_part == nil) || (@workflow_steps == nil) || (@timeout_reboot_classical == nil) || (@timeout_reboot_kexec == nil) ||
          (@pxe_header == nil) ||
          (@cmd_console == nil) || (@partition_creation_kind == nil) || (@partition_file == nil)) then
        puts "Some mandatory fields are missing in the specific configuration file for #{cluster}"
        return false
      else
        return true
      end
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
      if (@array_of_instances.length > (@current +1)) then
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
  end
end
