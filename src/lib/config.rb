# Kadeploy 3.0
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008, 2009
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

#Kadeploy libs
require 'environment'
require 'nodes'
require 'debug'

#Ruby libs
require 'optparse'
require 'ostruct'

module ConfigInformation
  CONFIGURATION_FOLDER = ENV['KADEPLOY_CONFIG_DIR']
  COMMANDS_FILE = "cmd"
  NODES_FILE = "nodes"
  COMMON_CONFIGURATION_FILE = "conf"
  CLIENT_CONFIGURATION_FILE = "client_conf"
  SPECIFIC_CONFIGURATION_FILE_PREFIX = "specific_conf_"
  PARTITION_FILE_PREFIX = "partition_file_"
  USER = `id -nu`.chomp

  class Config
    public

    attr_accessor :common
    attr_accessor :cluster_specific
    attr_accessor :exec_specific

    # Constructor of Config
    #
    # Arguments
    # * kind: tool (kadeploy, kaenv, karights, kastat, kareboot, kaconsole)
    # * nodes_desc(opt): set of nodes read from the configuration file
    # Output
    # * nothing if all is OK, otherwise raises an exception
    def initialize(kind, nodes_desc = nil)
      if (sanity_check(kind) == true) then
        case kind
        when "kadeploy"
          @common = CommonConfig.new
          res = load_common_config_file
          @cluster_specific = Hash.new
          res = res && load_cluster_specific_config_files
          res = res && load_nodes_config_file
          res = res && load_commands
        when "kaenv"
          res = load_kaenv_exec_specific
        when "karights"
          res = load_karights_exec_specific
        when "kastat"
          res = load_kastat_exec_specific
        when "kareboot"
          res = load_kareboot_exec_specific(nodes_desc)
        when "kaconsole"
          res = load_kaconsole_exec_specific(nodes_desc)
        when "kanodes"
          res = load_kanodes_exec_specific
        when "empty"
          res = true
        else
          puts "Invalid configuration kind: #{kind}"
          raise
        end
        if not res then
          puts "Problem in configuration"
          raise
        end
      else
        puts "Unsane configuration"
        raise
      end
    end


    # Check the config of the Kadeploy tools
    #
    # Arguments
    # * kind: tool (kadeploy, kaenv, karights, kastat, kareboot, kaconsole, kanodes)
    # Output
    # * calls the chack_config method that correspond to the selected tool
    def check_config(kind)
      case kind
      when "kadeploy"
        check_kadeploy_config
      when "kaenv"
        check_kaenv_config
      when "karights"
        check_karights_config
      when "kastat"
        check_kastat_config
      when "kareboot"
        check_kareboot_config
      when "kaconsole"
        check_kaconsole_config
      when "kanodes"
        check_kanodes_config
      end
    end

    # Load the kadeploy specific stuffs
    #
    # Arguments
    # * nodes_desc: set of nodes read from the configuration file
    # * db: database handler
    # Output
    # * exec_specific: return an open struct that contains the execution specific information
    #                  or nil if the command line is not correct
    def Config.load_kadeploy_exec_specific(nodes_desc, db)
      exec_specific = OpenStruct.new
      exec_specific.environment = EnvironmentManagement::Environment.new
      exec_specific.node_list = Nodes::NodeSet.new
      exec_specific.load_env_kind = String.new
      exec_specific.load_env_arg = String.new
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
      exec_specific.pxe_profile_file = String.new
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

      if (load_kadeploy_cmdline_options(nodes_desc, exec_specific) == true) then
        case exec_specific.load_env_kind
        when "file"
          if (exec_specific.environment.load_from_file(exec_specific.load_env_arg) == false) then
            return nil
          end
        when "db"
          if (exec_specific.environment.load_from_db(exec_specific.load_env_arg,
                                                     exec_specific.env_version,
                                                     exec_specific.user,
                                                     db) == false) then
            return nil
          end
        when ""
          Debug::client_error("You must choose an environment")
          return nil
        else
          puts "Invalid method for environment loading"
          raise
        end
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

##################################
#         Generic part           #
##################################

    # Perform a test to check the consistancy of the installation
    #
    # Arguments
    # * kind: specifies the program launched (kadeploy|kaenv)
    # Output
    # * return true if the installation is correct, false otherwise
    def sanity_check(kind)
      case kind
      when "kadeploy"
        if not File.readable?(CONFIGURATION_FOLDER + "/" + COMMON_CONFIGURATION_FILE) then
          puts "The #{CONFIGURATION_FOLDER + "/" + COMMON_CONFIGURATION_FILE} file cannot be read"
          return false
        end
        #configuration node file
        if not File.readable?(CONFIGURATION_FOLDER + "/" + NODES_FILE) then
          puts "The #{CONFIGURATION_FOLDER + "/" + NODES_FILE} file cannot be read"
          return false
        end
      when "kaenv"
      when "karights"
      when "kastat"
      when "kareboot"
      when "kaconsole"
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
      IO.readlines(CONFIGURATION_FOLDER + "/" + COMMON_CONFIGURATION_FILE).each { |line|
        if not (/^#/ =~ line) then #we ignore commented lines
          if /(.+)\ \=\ (.+)/ =~ line then
            content = Regexp.last_match
            attr = content[1]
            val = content[2]
            case attr
            when "verbose_level"
              if val =~ /\A[0-4]\Z/ then
                @common.verbose_level = val.to_i
              else
                puts "Invalid debug level"
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
            when "taktuk_ssh_connector"
              @common.taktuk_ssh_connector = val
            when "taktuk_rsh_connector"
              @common.taktuk_rsh_connector = val
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
              @common.kadeploy_cache_dir = val
            when "kadeploy_cache_size"
              @common.kadeploy_cache_size = val.to_i
            when "ssh_port"
              if val =~ /\A\d+\Z/ then
                @common.ssh_port = val
              else
                puts "Invalid value for SSH port"
                return false
              end
            when "rsh_port"
              if val =~ /\A\d+\Z/ then
                @common.rsh_port = val
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
            when "use_rsh_to_deploy"
              if val =~ /\A(true|false)\Z/ then
                @common.use_rsh_to_deploy = (val == "true")
              else
                puts "Invalid value for the use_rsh_to_deploy field"
                return false
              end
            when "environment_extraction_dir"
              @common.environment_extraction_dir = val
            when "log_to_file"
              @common.log_to_file = val
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
            when "nfsroot_kernel"
              @common.nfsroot_kernel = val
            when "nfs_server"
              @common.nfs_server = val
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
            end
          end
        end
      }
      return true
    end

    # Load the client configuration file
    #
    # Arguments
    # * nothing
    # Output
    # * return an open struct that contains some stuffs usefull for client
    def Config.load_client_config_file
      client_config = OpenStruct.new
      IO.readlines(CONFIGURATION_FOLDER + "/" + CLIENT_CONFIGURATION_FILE).each { |line|
        if not (/^#/ =~ line) then #we ignore commented lines
          if /(.+)\ \=\ (.+)/ =~ line then
            content = Regexp.last_match
            attr = content[1]
            val = content[2]
            case attr
            when "kadeploy_server"
              client_config.kadeploy_server = val
            when "kadeploy_server_port"
              client_config.kadeploy_server_port = val.to_i
            end
          end
        end
      }
      return client_config
    end

    # Load the specific configuration files
    #
    # Arguments
    # * nothing
    # Output
    # * return true in case of success, false otherwise
    def load_cluster_specific_config_files
      Dir[CONFIGURATION_FOLDER + "/" + SPECIFIC_CONFIGURATION_FILE_PREFIX + "*"].each { |f|
        cluster = String.new(f).sub(CONFIGURATION_FOLDER + "/" + SPECIFIC_CONFIGURATION_FILE_PREFIX, "")
        @cluster_specific[cluster] = ClusterSpecificConfig.new
        @cluster_specific[cluster].partition_file = CONFIGURATION_FOLDER + "/" + PARTITION_FILE_PREFIX + cluster
        IO.readlines(f).each { |line|
          if not (/^#/ =~ line) then #we ignore commented lines
            if /(.+)\ \=\ (.+)/ =~ line then
              content = Regexp.last_match
              attr = content[1]
              val = content[2]
              case attr
              when "deploy_kernel"
                @cluster_specific[cluster].deploy_kernel = val
              when "deploy_initrd"
                @cluster_specific[cluster].deploy_initrd = val
              when "prod_kernel"
                @cluster_specific[cluster].prod_kernel = val
              when "prod_initrd"
                @cluster_specific[cluster].prod_initrd = val
              when "block_device"
                @cluster_specific[cluster].block_device = val
              when "deploy_part"
                if val =~ /\A\d+\Z/ then
                  @cluster_specific[cluster].deploy_part = val
                else
                  puts "Invalid value for the deploy_part field in the #{cluster} config file"
                  return false
                end
              when "prod_part"
                if val =~ /\A\d+\Z/ then
                  @cluster_specific[cluster].prod_part = val
                else
                  puts "Invalid value for the prod_part field in the #{cluster} config file"
                  return false
                end
              when "tmp_part"
                if val =~ /\A\d+\Z/ then
                  @cluster_specific[cluster].tmp_part = val
                else
                  puts "Invalid value for the tmp_part field in the #{cluster} config file"
                  return false
                end
              when "workflow_steps"
                @cluster_specific[cluster].workflow_steps = val
              when "timeout_reboot"
                if val =~ /\A\d+\Z/ then
                  @cluster_specific[cluster].timeout_reboot = val.to_i
                else
                  puts "Invalid value for the timeout_reboot field in the #{cluster} config file"
                  return false
                end
              when "cmd_soft_reboot_rsh"
                @cluster_specific[cluster].cmd_soft_reboot_rsh = val
              when "cmd_soft_reboot_ssh"
                @cluster_specific[cluster].cmd_soft_reboot_ssh = val
              when "cmd_hard_reboot"
                @cluster_specific[cluster].cmd_hard_reboot = val
              when "cmd_very_hard_reboot"
                @cluster_specific[cluster].cmd_very_hard_reboot = val
              when "cmd_console"
                @cluster_specific[cluster].cmd_console = val
              when "drivers"
                val.split(",").each { |driver|
                  @cluster_specific[cluster].drivers.push(driver)
                }
              when "kernel_params"
                 @cluster_specific[cluster].kernel_params = val
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
              end
            end
          end
        }
        if @cluster_specific[cluster].check_all_fields_filled(cluster) == false then
          return false
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
      IO.readlines(CONFIGURATION_FOLDER + "/" + NODES_FILE).each { |line|
        if /\A([A-Za-z0-9\.\-]+)\ (\d{1,3}.\d{1,3}.\d{1,3}.\d{1,3})\ ([A-Za-z0-9\.\-]+)\Z/ =~ line
          content = Regexp.last_match
          host = content[1]
          ip = content[2]
          cluster = content[3]
          @common.nodes_desc.push(Nodes::Node.new(host, ip, cluster, generate_commands(host, cluster)))
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
      commands_file = CONFIGURATION_FOLDER + "/" + COMMANDS_FILE
      if File.readable?(commands_file) then
        IO.readlines(commands_file).each { |line|
          if not ((/^#/ =~ line) || (/^$/)) then #we ignore commented lines and empty lines
            if /(.+)\|(.+)\|(.+)/ =~ line then
              content = Regexp.last_match
              node = @common.nodes_desc.get_node_by_host(content[1])
              case content[2]
              when "reboot_soft_rsh"
                node.cmd.reboot_soft_rsh = content[3]
              when "reboot_soft_ssh"
                node.cmd.reboot_soft_ssh = content[3]
              when "reboot_hard"
                node.cmd.reboot_hard = content[3]
              when "reboot_veryhard"
              node.cmd.reboot_veryhard = content[3]
              when "console"
                node.cmd.console = content[3]
              else
                puts "Unknown command: #{content[2]}"
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

    # Replace the substrings HOSTNAME_FQDN and HOSTNAME_SHORT in a string by a value
    #
    # Arguments
    # * str: string in which the HOSTNAME_FQDN and HOSTNAME_SHORT values must be replaced
    # * hostname: value used for the replacement
    # Output
    # * return the new string       
    def replace_hostname(str, hostname)
      cmd_to_expand = str.clone # we must use this temporary variable since sub() modify the strings
      save = str
      while cmd_to_expand.sub!("HOSTNAME_FQDN", hostname) != nil  do
        save = cmd_to_expand
      end
      while cmd_to_expand.sub!("HOSTNAME_SHORT", hostname.split(".")[0]) != nil  do
        save = cmd_to_expand
      end
      return save
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
        cmd.reboot_soft_rsh = replace_hostname(@cluster_specific[cluster].cmd_soft_reboot_rsh, hostname)
        cmd.reboot_soft_ssh = replace_hostname(@cluster_specific[cluster].cmd_soft_reboot_ssh, hostname)
        cmd.reboot_hard = replace_hostname(@cluster_specific[cluster].cmd_hard_reboot, hostname)
        cmd.reboot_very_hard = replace_hostname(@cluster_specific[cluster].cmd_very_hard_reboot, hostname)
        cmd.console = replace_hostname(@cluster_specific[cluster].cmd_console, hostname)
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
    # * nodes_desc: set of nodes read from the configuration file
    # * exec_specific: open struct that contains some execution specific stuffs (modified)
    # Output
    # * return true in case of success, false otherwise
    def Config.load_kadeploy_cmdline_options(nodes_desc, exec_specific)
      opts = OptionParser::new do |opts|
        opts.summary_indent = "  "
        opts.summary_width = 32
        opts.banner = "Usage: kadeploy [options]"
        opts.separator "Contact: kadeploy-devel@lists.grid5000.fr"
        opts.separator ""
        opts.separator "General options:"
        opts.on("-a", "--env-file ENVFILE", "File containing the envrionement description") { |f|
          if not File.readable?(f) then
            Debug::client_error("The file #{f} does not exist or is not readable")
            return false
          else
            exec_specific.load_env_kind = "file"
            exec_specific.load_env_arg = f
          end
        }
        opts.on("-b", "--block-device BLOCKDEVICE", "Specify the block device to use") { |b|
          if /\A[\w\/]+\Z/ =~ b then
            exec_specific.block_device = b
          else
            Debug::client_error("Invalid block device")
            return false
          end
        }
        opts.on("-d", "--debug-mode", "Activate the debug mode") {
          exec_specific.debug = true
        }
        opts.on("-e", "--env-name ENVNAME", "Name of the recorded environment to deploy") { |n|
          exec_specific.load_env_kind = "db"
          exec_specific.load_env_arg = n
        }
        opts.on("-f", "--file MACHINELIST", "Files containing list of nodes")  { |f|
          if not File.readable?(f) then
            Debug::client_error("The file #{f} cannot be read")
            return false
          else
            IO.readlines(f).sort.uniq.each { |hostname|
              if not (/\A[A-Za-z0-9\.\-]+\Z/ =~ hostname) then
                Debug::client_error("Invalid hostname: #{hostname}")
                return false
              end
              if (not add_to_node_list(hostname.chomp, nodes_desc, exec_specific)) then
                return false
              end
            }
          end
        }
        opts.on("-k", "--key [FILE]", "Public key to copy in the root's authorized_keys, if no argument is specified, use the authorized_keys") { |f|
          if (f != nil) then
            if not File.readable?(f) then
              Debug::client_error("The file #{f} cannot be read")
              return false
            else
              exec_specific.key = File.expand_path(f)
            end
          else
            authorized_keys = "~/.ssh/authorized_keys"
            if File.readable?(authorized_keys) then
              exec_specific.key = File.expand_path(authorized_keys)
            else
              Debug::client_error("The authorized_keys file #{authorized_keys} cannot be read")
              return false
            end
          end
        }
        opts.on("-m", "--machine MACHINE", "Node to run on") { |hostname|
          if not (/\A[A-Za-z0-9\.\-]+\Z/ =~ hostname) then 
            Debug::client_error("Invalid hostname: #{hostname}")
            return false
          end
          if (not add_to_node_list(hostname, nodes_desc, exec_specific)) then
            return false
          end
        }
        opts.on("-n", "--output-ko-nodes FILENAME", "File that will contain the nodes not correctly deployed")  { |f|
          exec_specific.nodes_ko_file = f
        }
        opts.on("-o", "--output-ok-nodes FILENAME", "File that will contain the nodes correctly deployed")  { |f|
          exec_specific.nodes_ok_file = f
        }
        opts.on("-p", "--partition-number NUMBER", "Specify the partition number to use") { |p|
          if /\A[1-9]\d*\Z/ =~ p then
            exec_specific.deploy_part = p
          else
            Debug::client_error("Invalid partition number")
            return false
          end
        }
        opts.on("-r", "--reformat-tmp", "Reformat the /tmp partition") {
          exec_specific.reformat_tmp = true
        }
        opts.on("-s", "--script FILE", "Execute a script at the end of the deployment") { |f|
          if not File.readable?(f) then
            Debug::client_error("The file #{f} cannot be read")
            return false
          else
            if not File.stat(f).executable? then
              Debug::client_error("The file #{f} must be executable to be run at the end of the deployment")
              return false
            else
              exec_specific.script = File.expand_path(f)
            end
          end
        }
        opts.on("-u", "--user USERNAME", "Specify the user") { |u|
          if /\A\w+\Z/ =~ u then
            exec_specific.user = u
          else
            Debug::client_error("Invalid user name")
            return false
          end
        }
        opts.on("-v", "--env-version NUMVERSION", "Number of version of the environment to deploy") { |n|
          if /\A\d+\Z/ =~ n then
            exec_specific.env_version = n
          else
            Debug::client_error("Invalid version number")
            return false
          end
        }
        opts.on("--verbose-level VALUE", "Verbose level between 0 to 4") { |d|
          if d =~ /\A[0-4]\Z/ then
            exec_specific.verbose_level = d.to_i
          else
            Debug::client_error("Invalid verbose level")
            return false
          end
        }
        opts.on("-w", "--set-pxe-profile FILE", "Set the PXE profile (use with caution)") { |f|
          if not File.readable?(f) then
            Debug::client_error("The file #{f} cannot be read")
            return false
          else
            exec_specific.pxe_profile_file = f
          end
        }
        opts.separator "Advanced options:"
        opts.on("--write-workflow-id FILE", "Write the workflow id in a file") { |file|
          exec_specific.write_workflow_id = file
        }
        opts.on("--ignore-nodes-deploying", "Allow to deploy even on the nodes tagged as \"currently deploying\" (use this only if you know what you do)") {
          exec_specific.ignore_nodes_deploying = true
        }        
        opts.on("--disable-bootloader-install", "Disable the automatic installation of a bootloader for a Linux based environnment") {
          exec_specific.disable_bootloader_install = true
        }
        opts.on("--disable-disk-partitioning", "Disable the disk partitioning") {
          exec_specific.disable_disk_partitioning = true
        }
        opts.on("--breakpoint MICROSTEP", "Set a breakpoint just before lauching the given micro-step, the syntax is macrostep:microstep (use this only if you know what you do)") { |m|
          if (m =~ /\A[a-zA-Z0-9_]+:[a-zA-Z0-9_]+\Z/)
            exec_specific.breakpoint_on_microstep = m
          else
            Debug::client_error("The value #{m} for the breakpoint entry is invalid")
            return false
          end
        }
        opts.on("--set-custom-operations FILE", "Add some custom operations defined in a file") { |file|
          exec_specific.custom_operations_file = file
          if not File.readable?(file) then
            Debug::client_error("The file #{file} cannot be read")
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
        opts.on("--force-steps STRING", "Undocumented, for administration purpose only") { |s|
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
      begin
        opts.parse!(ARGV)
      rescue 
        Debug::client_error("Option parsing error")
        return false
      end
      if exec_specific.node_list.empty? then
        Debug::client_error("You must specify some nodes to deploy")
        return false
      end

      if (exec_specific.nodes_ok_file != "") && (exec_specific.nodes_ok_file == exec_specific.nodes_ko_file) then
        Debug::client_error("The files used for the output of the OK and the KO nodes must not be the same")
        return false
      end

      return true
    end

    # Add a node involved in the deployment to the exec_specific.node_list
    #
    # Arguments
    # * hostname: hostname of the node
    # * nodes_desc: set of nodes read from the configuration file
    # * exec_specific: open struct that contains some execution specific stuffs (modified)
    # Output
    # * return true if the node exists in the Kadeploy configuration, false otherwise
    def Config.add_to_node_list(hostname, nodes_desc, exec_specific)
      n = nodes_desc.get_node_by_host(hostname)
      if (n != nil) then
        exec_specific.node_list.push(n)
        return true
      else
        Debug::client_error("The node #{hostname} does not exist in the Kadeploy configuration")
        return false
      end
    end

    # Check the whole configuration of the kadeploy execution
    #
    # Arguments
    # * nothing
    # Output
    # * return true if the options used are correct, false otherwise
    # Fixme
    # * should add more tests
    def check_kadeploy_config
      if not @common.check_all_fields_filled() then
        return false
      end
      #tftp directory
      if not File.exist?(@common.tftp_repository) then
        puts "The #{@common.tftp_repository} directory does not exist"
        return false
      end
      if not File.exist?(@common.kadeploy_cache_dir) then
        puts "The #{@common.kadeploy_cache_dir} directory does not exist, let's create it"
        res = Dir.mkdir(@common.kadeploy_cache_dir, 0700) rescue false
        if res.kind_of? FalseClass then
          puts "The directory cannot be created"
          return false
        end
      end
      #tftp image directory
      if not File.exist?(@common.tftp_repository + "/" + @common.tftp_images_path) then
        puts "The #{@common.tftp_repository}/#{@common.tftp_images_path} directory does not exist"
        return false
      end
      #tftp config directory
      if not File.exist?(@common.tftp_repository + "/" + @common.tftp_cfg) then
        puts "The #{@common.tftp_repository}/#{@common.tftp_cfg} directory does not exist"
        return false
      end
     
      @cluster_specific.each_key { |cluster|
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
              puts "The admin_pre_install file #{entry["file"]} does not exist"
              return false
            else
              if ((entry["kind"] != "tgz") && (entry["kind"] != "tbz2")) then
              puts "Only tgz and tbz2 file kinds are allowed for postinstall files"
                return false
              end
            end
          }
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
    def load_kaenv_exec_specific
      @exec_specific = OpenStruct.new
      @exec_specific.environment = EnvironmentManagement::Environment.new
      @exec_specific.operation = String.new
      @exec_specific.file = String.new
      @exec_specific.env_name = String.new
      @exec_specific.user = USER #By default, we use the current user
      @exec_specific.visibility_tag = String.new
      @exec_specific.show_all_version = false
      @exec_specific.version = String.new
      @exec_specific.files_to_move = Array.new
      return load_kaenv_cmdline_options()
    end

    # Load the command-line options of kaenv
    #
    # Arguments
    # * nothing
    # Output
    # * return true in case of success, false otherwise
    def load_kaenv_cmdline_options
      opts = OptionParser::new do |opts|
        opts.summary_indent = "  "
        opts.summary_width = 36
        opts.banner = "Usage: kaenv [options]"
        opts.separator "Contact: kadeploy-devel@lists.grid5000.fr"
        opts.separator ""
        opts.separator "General options:"
        opts.on("-e", "--environment ENVNAME", "Environment name") { |n|
          @exec_specific.env_name = n
        }        
        opts.on("-f", "--file FILE", "Environment file") { |f|
          if not File.readable?(f) then
            Debug::client_error("The file #{f} cannot be read")
            return false
          else
            @exec_specific.file = f
          end
        }
        opts.on("-m", "--files-to-move FILES", "Files to move (src1:dst1,src2:dst2,...)") { |f|
          if /\A.+:.+(,.+:.+)*\Z/ =~f then
            f.split(",").each { |src_dst|
              @exec_specific.files_to_move.push({"src"=>src_dst.split(":")[0],"dest"=>src_dst.split(":")[1]})
            }
          else
            Debug::client_error("Invalid synthax for files to move")
            return false
          end
        }
        opts.on("-o", "--operation OPERATION", "Kind of operation (add, delete, list, print, remove-demolishing-tag, set-visibility-tag, update-tarball-md5, update-preinstall-md5, update-postinstalls-md5, move-files)") { |op|
          if /\A(add|delete|list|print|remove-demolishing-tag|set-visibility-tag|update-tarball-md5|update-preinstall-md5|update-postinstalls-md5|move-files)\Z/ =~ op then
            @exec_specific.operation = op
          else
            Debug::client_error("Invalid operation")
          end
        }
        opts.on("-s", "--show-all-versions", "Show all versions of an environment") {
          @exec_specific.show_all_version = true
        }
        opts.on("-t", "--visibility-tag TAG", "Set the visibility tag (private, shared, public)") { |v|
          if /\A(private|shared|public)\Z/ =~ v then
            @exec_specific.visibility_tag = v
          else
            Debug::client_error("Invalid visibility tag")
          end
        }
        opts.on("-u", "--user USERNAME", "Specify the user") { |u|
          if /\A(\w+)|\*\Z/ =~ u then
            @exec_specific.user = u
          else
            Debug::client_error("Invalid user name")
            return false
          end
        }
        opts.on("-v", "--version NUMBER", "Specify the version") { |v|
          if /\A\d+\Z/ =~ v then
            @exec_specific.version = v
          else
            Debug::client_error("Invalid version number")
            return false
          end
        }
      end
      begin
        opts.parse!(ARGV)
      rescue 
        Debug::client_error("Option parsing error")
        return false
      end
      return true
    end

    # Check the whole configuration of the kaenv execution
    #
    # Arguments
    # * nothing
    # Output
    # * return true if the options used are correct, false otherwise
    # Fixme
    # * should add more tests
    def check_kaenv_config
      case @exec_specific.operation 
      when "add"
        if (@exec_specific.file == "") then
          Debug::client_error("You must choose a file that contains the environment description")
          return false
        end
      when "delete"
        if (@exec_specific.env_name == "") then
          Debug::client_error("You must choose an environment")
          return false
        end
      when "list"
      when "print"
        if (@exec_specific.env_name == "") then
          Debug::client_error("You must choose an environment")
          return false
        end
      when "update-tarball-md5"
        if (@exec_specific.env_name == "") then
          Debug::client_error("You must choose an environment")
          return false
        end
      when "update-preinstall-md5"
        if (@exec_specific.env_name == "") then
          Debug::client_error("You must choose an environment")
          return false
        end
      when "update-postinstalls-md5"
        if (@exec_specific.env_name == "") then
          Debug::client_error("You must choose an environment")
          return false
        end
      when "remove-demolishing-tag"
        if (@exec_specific.env_name == "") then
          Debug::client_error("You must choose an environment")
          return false
        end
      when "set-visibility-tag"
        if (@exec_specific.env_name == "") then
          Debug::client_error("You must choose an environment")
          return false
        end
        if (@exec_specific.version == "") then
          Debug::client_error("You must choose a version")
          return false
        end
        if (@exec_specific.visibility_tag == "") then
          Debug::client_error("You must define the visibility value")
          return false          
        end
      when "move-files"
        if (@exec_specific.files_to_move.empty?) then
          Debug::client_error("You must define some files to move")
          return false          
        end
      else
        Debug::client_error("You must choose an operation")
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
    def load_karights_exec_specific
      @exec_specific = OpenStruct.new
      @exec_specific.operation = String.new
      @exec_specific.user = String.new
      @exec_specific.part_list = Array.new
      @exec_specific.node_list = Array.new
      return load_karights_cmdline_options()
    end

    # Load the command-line options of karights
    #
    # Arguments
    # * nothing
    # Output
    # * return true in case of success, false otherwise
    def load_karights_cmdline_options
      opts = OptionParser::new do |opts|
        opts.summary_indent = "  "
        opts.summary_width = 28
        opts.banner = "Usage: karights [options]"
        opts.separator "Contact: kadeploy-devel@lists.grid5000.fr"
        opts.separator ""
        opts.separator "General options:"
        opts.on("-a", "--add", "Add some rights to a user") {
          @exec_specific.operation = "add"
        }
        opts.on("-d", "--delete", "Delete some rights to a user") {
          @exec_specific.operation = "delete"
        }
        opts.on("-m", "--machine MACHINE", "Include the machine in the operation") { |m|
          if (not (/\A[A-Za-z0-9\.\-]+\Z/ =~ m)) and (m != "*") then
            Debug::client_error("Invalid hostname: #{m}")
            return false
          end
          @exec_specific.node_list.push(m)
        }
        opts.on("-p", "--part PARTNAME", "Include the partition in the operation") { |p|
          @exec_specific.part_list.push(p)
        }        
        opts.on("-s", "--show-rights", "Show the rights for a given user") {
          @exec_specific.operation = "show"
        }
        opts.on("-u", "--user USERNAME", "Specify the user") { |u|
          if /\A\w+\Z/ =~ u then
            @exec_specific.user = u
          else
            Debug::client_error("Invalid user name")
            return false
          end
        }
      end
      begin
        opts.parse!(ARGV)
      rescue 
        Debug::client_error("Option parsing error")
        return false
      end
      return true
    end

    # Check the whole configuration of the karigths execution
    #
    # Arguments
    # * nothing
    # Output
    # * return true if the options used are correct, false otherwise
    def check_karights_config
      if (@exec_specific.user == "") then
        Debug::client_error("You must choose a user")
        return false
      end
      case
      when @exec_specific.operation == "add" || @exec_specific.operation  == "delete"
        if (@exec_specific.part_list.empty?) then
          Debug::client_error("You must specify at list one partition")
          return false
        end
        if (@exec_specific.node_list.empty?) then
          Debug::client_error("You must specify at list one node")
          return false
        end
      when @exec_specific.operation == "show"
      else
        Debug::client_error("You must choose an operation")
        return false
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
    def load_kastat_exec_specific
      @exec_specific = OpenStruct.new
      @exec_specific.operation = String.new
      @exec_specific.date_min = 0
      @exec_specific.date_max = 0
      @exec_specific.min_retries = 0
      @exec_specific.min_rate = 0
      @exec_specific.node_list = Array.new
      @exec_specific.steps = Array.new
      @exec_specific.fields = Array.new
      return load_kastat_cmdline_options()
    end

    # Load the command-line options of kastat
    #
    # Arguments
    # * nothing
    # Output
    # * return true in case of success, false otherwise
    def load_kastat_cmdline_options
      opts = OptionParser::new do |opts|
        opts.summary_indent = "  "
        opts.summary_width = 28
        opts.banner = "Usage: kastat [options]"
        opts.separator "Contact: kadeploy-devel@lists.grid5000.fr"
        opts.separator ""
        opts.separator "General options:"
        opts.on("-a", "--list-min-retries NB", "Print the statistics about the nodes that need several attempts") { |n|
          if /\A\d+\Z/ =~ n then
            @exec_specific.operation = "list_retries"
            @exec_specific.min_retries = n.to_i
          else
            Debug::client_error("Invalid number of minimum retries, ignoring the option")
            return false
          end
        }
        opts.on("-b", "--list-failure-rate", "Print the failure rate for the nodes") { |n|
          @exec_specific.operation = "list_failure_rate"
        }
        opts.on("-c", "--list-min-failure-rate RATE", "Print the nodes which have a minimum failure-rate of RATE (0 <= RATE <= 100") { |r|
          if ((/\A\d+/ =~ r) && ((r.to_i >= 0) && ((r.to_i <= 100)))) then
            @exec_specific.operation = "list_min_failure_rate"
            @exec_specific.min_rate = r.to_i
          else
            Debug::client_error("Invalid number for the minimum failure rate, ignoring the option")
            return false
          end
        }
        opts.on("-d", "--list-all", "Print all the information") { |r|
          @exec_specific.operation = "list_all"
        }
        opts.on("-f", "--field FIELD", "Only print the given fields (user,hostname,step1,step2,step3,timeout_step1,timeout_step2,timeout_step3,retry_step1,retry_step2,retry_step3,start,step1_duration,step2_duration,step3_duration,env,md5,success,error)") { |f|
          @exec_specific.fields.push(f)
        }
        opts.on("-m", "--machine MACHINE", "Only print information about the given machines") { |m|
          if not (/\A[A-Za-z0-9\.\-]+\Z/ =~ m) then
            Debug::client_error("Invalid hostname: #{m}")
            return false
          end
          @exec_specific.node_list.push(m)
        }
        opts.on("-s", "--step STEP", "Applies the retry filter on the given steps (1, 2 or 3)") { |s|
          @exec_specific.steps.push(s) 
        }
        opts.on("-x", "--date-min DATE", "Get the stats from this date (yyyy:mm:dd:hh:mm:ss)") { |d|
          @exec_specific.date_min = d
        }
        opts.on("-y", "--date-max DATE", "Get the stats to this date") { |d|
          @exec_specific.date_max = d
        }
      end
      begin
        opts.parse!(ARGV)
      rescue 
        Debug::client_error("Option parsing error")
        return false
      end
      return true
    end

    # Check the whole configuration of the kastat execution
    #
    # Arguments
    # * nothing
    # Output
    # * return true if the options used are correct, false otherwise
    def check_kastat_config
      if (@exec_specific.operation == "") then
        Debug::client_error("You must choose an operation")
        return false
      end
      authorized_fields = ["user","hostname","step1","step2","step3", \
                           "timeout_step1","timeout_step2","timeout_step3", \
                           "retry_step1","retry_step2","retry_step3", \
                           "start", \
                           "step1_duration","step2_duration","step3_duration", \
                           "env","anonymous_env","md5", \
                           "success","error"]
      @exec_specific.fields.each { |f|
        if (not authorized_fields.include?(f)) then
          Debug::client_error("The field \"#{f}\" does not exist")
          return false
        end
      }
      if (@exec_specific.date_min != 0) then
        if not (/^\d{4}:\d{2}:\d{2}:\d{2}:\d{2}:\d{2}$/ === @exec_specific.date_min) then
          Debug::client_error("The date #{@exec_specific.date_min} is not correct")
          return false
        else
          str = @exec_specific.date_min.split(":")
          @exec_specific.date_min = Time.mktime(str[0], str[1], str[2], str[3], str[4], str[5]).to_i
        end
      end
      if (@exec_specific.date_max != 0) then
        if not (/^\d{4}:\d{2}:\d{2}:\d{2}:\d{2}:\d{2}$/ === @exec_specific.date_max) then
          Debug::client_error("The date #{@exec_specific.date_max} is not correct")
          return false
        else
          str = @exec_specific.date_max.split(":")
          @exec_specific.date_max = Time.mktime(str[0], str[1], str[2], str[3], str[4], str[5]).to_i
        end
      end
      authorized_steps = ["1","2","3"]
      @exec_specific.steps.each { |s|
         if (not authorized_steps.include?(s)) then
           Debug::client_error("The step \"#{s}\" does not exist")
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
    def load_kanodes_exec_specific
      @exec_specific = OpenStruct.new
      @exec_specific.operation = String.new
      @exec_specific.node_list = Array.new
      @exec_specific.wid = String.new
      return load_kanodes_cmdline_options()
    end

    # Load the command-line options of kanodes
    #
    # Arguments
    # * nothing
    # Output
    # * return true in case of success, false otherwise
    def load_kanodes_cmdline_options
      opts = OptionParser::new do |opts|
        opts.summary_indent = "  "
        opts.summary_width = 28
        opts.banner = "Usage: kanodes [options]"
        opts.separator "Contact: kadeploy-devel@lists.grid5000.fr"
        opts.separator ""
        opts.separator "General options:"
        opts.on("-b", "--get-state", "") {
          @exec_specific.operation = list 
        }       
        opts.on("-f", "--file MACHINELIST", "Only print information about the given machines")  { |f|
          if not File.readable?(f) then
            Debug::client_error("The file #{f} cannot be read")
            return false
          else
            IO.readlines(f).sort.uniq.each { |hostname|
              if not (/\A[A-Za-z0-9\.\-]+\Z/ =~ hostname) then
                Debug::client_error("Invalid hostname: #{hostname}")
                return false
              end
              @exec_specific.node_list.push(hostname.chomp)
            }
          end
        }
        opts.on("-m", "--machine MACHINE", "Only print information about the given machines") { |m|
          if not (/\A[A-Za-z0-9\.\-]+\Z/ =~m) then
            Debug::client_error("Invalid hostname: #{m}")
            return false
          end
          @exec_specific.node_list.push(m)
        }
        opts.on("-o", "--operation OPERATION", "Choose the operation (get_deploy_state or get_yaml_dump)") { |o|
          if not  (/\A(get_deploy_state|get_yaml_dump)\Z/ =~ o) then
            Debug::client_error("Invalid operation: #{o}")
            return false
          end
          @exec_specific.operation = o
        }
        opts.on("-w", "--workflow-id WID", "Specify a workflow id (this is use with the get_yaml_dump operation. If no wid is specified, the information of all the running worklfows will be dumped") { |w|
          @exec_specific.wid = w
        }
      end
      begin
        opts.parse!(ARGV)
      rescue 
        Debug::client_error("Option parsing error")
        return false
      end
      return true
    end

    # Check the whole configuration of the kanodes execution
    #
    # Arguments
    # * nothing
    # Output
    # * return true if the options used are correct, false otherwise
    def check_kanodes_config
      if (exec_specific.operation == "") then
        Debug::client_error("You must choose an operation")
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
    def load_kareboot_exec_specific(nodes_desc)
      @exec_specific = OpenStruct.new
      @exec_specific.verbose_level = String.new
      @exec_specific.node_list = Nodes::NodeSet.new
      @exec_specific.pxe_profile_file = String.new
      @exec_specific.check_prod_env = false
      @exec_specific.true_user = USER
      @exec_specific.breakpoint_on_microstep = "none"
      @exec_specific.key = String.new
      return load_kareboot_cmdline_options(nodes_desc)
    end

    # Load the command-line options of kareboot
    #
    # Arguments
    # * nothing
    # Output
    # * return true in case of success, false otherwise
    def load_kareboot_cmdline_options(nodes_desc)
      opts = OptionParser::new do |opts|
        opts.summary_indent = "  "
        opts.summary_width = 30
        opts.banner = "Usage: kareboot [options]"
        opts.separator "Contact: kadeploy-devel@lists.grid5000.fr"
        opts.separator ""
        opts.separator "General options:"
        opts.on("-c", "--check-prod-env", "Check if the production environment has been detroyed") { |d|
          @exec_specific.check_prod_env = true
        }
        opts.on("-f", "--file MACHINELIST", "Files containing list of nodes")  { |f|
          if not File.readable?(f) then
            Debug::client_error("The file #{f} cannot be read")
            return false
          else
            IO.readlines(f).sort.uniq.each { |hostname|
              if not (/\A[A-Za-z0-9\.\-]+\Z/ =~ hostname) then
                Debug::client_error("Invalid hostname: #{hostname}")
                return false
              end
              Config.add_to_node_list(hostname.chomp, nodes_desc, @exec_specific)
            }
          end
        }
        opts.on("-k", "--key FILE", "Public key to copy in the root's authorized_keys") { |f|
          if not File.readable?(f) then
            Debug::client_error("The file #{f} cannot be read")
            return false
          else
            @exec_specific.key = File.expand_path(f)
          end
        }
        opts.on("-m", "--machine MACHINE", "Reboot the given machines") { |hostname|
          if not (/\A[A-Za-z0-9\.\-]+\Z/ =~ hostname) then
            Debug::client_error("Invalid hostname: #{hostname}")
            return false
          end
          Config.add_to_node_list(hostname, nodes_desc, @exec_specific)
        }
        opts.on("-r", "--reboot-kind REBOOT_KIND", "Specify the reboot kind (back_to_prod_env, set_pxe, simple_reboot, deploy_env)") { |k|
          @exec_specific.reboot_kind = k
        }
        opts.on("--verbose-level VALUE", "Verbose level between 0 to 4") { |d|
          if d =~ /\A[0-4]\Z/ then
            @exec_specific.verbose_level = d.to_i
          else
            Debug::client_error("Invalid verbose level")
            return false
          end
        }
        opts.on("-w", "--set-pxe-profile FILE", "Set the PXE profile (use with caution)") { |file|
          @exec_specific.pxe_profile_file = file
        }      
      end
      begin
        opts.parse!(ARGV)
      rescue 
        Debug::client_error("Option parsing error")
        return false
      end
      return true
    end

    # Check the whole configuration of the kareboot execution
    #
    # Arguments
    # * nothing
    # Output
    # * return true if the options used are correct, false otherwise
    def check_kareboot_config
      if @exec_specific.node_list.empty? then
        Debug::client_error("No node is chosen")
        return false
      end    
      if (@exec_specific.verbose_level != "") && ((@exec_specific.verbose_level > 4) || (@exec_specific.verbose_level < 0)) then
        Debug::client_error("Invalid debug level")
        return false
      end
      authorized_ops = ["back_to_prod_env", "set_pxe", "simple_reboot", "deploy_env"]
      if not authorized_ops.include?(@exec_specific.reboot_kind) then
        Debug::client_error("Invalid kind of reboot: #{@exec_specific.reboot_kind}")
        return false
      end        
      if (@exec_specific.pxe_profile_file != "") && (not File.readable?(@exec_specific.pxe_profile_file)) then
        Debug::client_error("The file #{@exec_specific.pxe_profile_file} cannot be read")
        return false
      end
      if (@exec_specific.reboot_kind == "set_pxe") && (@exec_specific.pxe_profile_file == "") then
        Debug::client_error("The set_pxe reboot must be used with the -w option")
        return false
      end
      if (@exec_specific.key != "") && (@exec_specific.reboot_kind != "deploy_env") then
        Debug::client_error("The -k option can be only used with the deploy_env reboot kind")
        return false
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
    def load_kaconsole_exec_specific(nodes_desc)
      @exec_specific = OpenStruct.new
      @exec_specific.node = nil
      return load_kaconsole_cmdline_options(nodes_desc)
    end

    # Load the command-line options of kaconsole
    #
    # Arguments
    # * nothing
    # Output
    # * return true in case of success, false otherwise
    def load_kaconsole_cmdline_options(nodes_desc)
      opts = OptionParser::new do |opts|
        opts.summary_indent = "  "
        opts.summary_width = 28
        opts.banner = "Usage: kaconsole [options]"
        opts.separator "Contact: kadeploy-devel@lists.grid5000.fr"
        opts.separator ""
        opts.separator "General options:"
        opts.on("-m", "--machine MACHINE", "Obtain a console on the given machines") { |hostname|
          if not (/\A[A-Za-z0-9\.\-]+\Z/ =~ hostname) then
            Debug::client_error("Invalid hostname: #{hostname}")
            return false
          end
          n = nodes_desc.get_node_by_host(hostname)
          if (n != nil) then
            @exec_specific.node = n
          else
            Debug::client_error("Invalid hostname \"#{hostname}\"")
            return false
          end
        }
      end
      begin
        opts.parse!(ARGV)
      rescue 
        Debug::client_error("Option parsing error")
        return false
      end
      return true
    end

    # Check the whole configuration of the kaconsole execution
    #
    # Arguments
    # * nothing
    # Output
    # * return true if the options used are correct, false otherwise
    def check_kaconsole_config
      if (@exec_specific.node == nil) then
        Debug::client_error("You must choose one node")
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
    attr_accessor :taktuk_ssh_connector
    attr_accessor :taktuk_rsh_connector
    attr_accessor :taktuk_connector
    attr_accessor :taktuk_tree_arity
    attr_accessor :taktuk_auto_propagate
    attr_accessor :tarball_dest_dir
    attr_accessor :kadeploy_server
    attr_accessor :kadeploy_server_port
    attr_accessor :kadeploy_tcp_buffer_size
    attr_accessor :kadeploy_cache_dir
    attr_accessor :kadeploy_cache_size
    attr_accessor :ssh_port
    attr_accessor :rsh_port
    attr_accessor :test_deploy_env_port
    attr_accessor :use_rsh_to_deploy
    attr_accessor :environment_extraction_dir
    attr_accessor :log_to_file
    attr_accessor :log_to_syslog
    attr_accessor :log_to_db
    attr_accessor :dbg_to_syslog
    attr_accessor :dbg_to_syslog_level
    attr_accessor :reboot_window
    attr_accessor :reboot_window_sleep_time
    attr_accessor :nodes_check_window
    attr_accessor :nfsroot_kernel
    attr_accessor :nfs_server
    attr_accessor :bootloader
    attr_accessor :purge_deployment_timer
    attr_accessor :rambin_path
    attr_accessor :mkfs_options
    attr_accessor :demolishing_env_threshold
    attr_accessor :bt_tracker_ip
    attr_accessor :bt_download_timeout
    attr_accessor :almighty_env_users

    # Constructor of CommonConfig
    #
    # Arguments
    # * nothing
    # Output
    # * nothing
    def initialize
      @nodes_desc = Nodes::NodeSet.new
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
          (@taktuk_ssh_connector == nil) || (@taktuk_rsh_connector == nil) ||
          (@taktuk_tree_arity == nil) || (@taktuk_auto_propagate == nil) || (@tarball_dest_dir == nil) ||
          (@kadeploy_server == nil) || (@kadeploy_server_port == nil) ||
          (@kadeploy_tcp_buffer_size == nil) || (@kadeploy_cache_dir == nil) || (@kadeploy_cache_size == nil) ||
          (@ssh_port == nil) || (@rsh_port == nil) || (@test_deploy_env_port == nil) || (@use_rsh_to_deploy == nil) ||
          (@environment_extraction_dir == nil) || (@log_to_file == nil) || (@log_to_syslog == nil) || (@log_to_db == nil) ||
          (@dbg_to_syslog == nil) || (@dbg_to_syslog_level == nil) || (@reboot_window == nil) || 
          (@reboot_window_sleep_time == nil) || (@nodes_check_window == nil) || (@nfsroot_kernel == nil) ||
          (@nfs_server == nil) || (@bootloader == nil) || (@purge_deployment_timer == nil) || (@rambin_path == nil) ||
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
    attr_accessor :prod_kernel
    attr_accessor :prod_initrd
    attr_accessor :tmp_part
    attr_accessor :workflow_steps   #Array of MacroStep
    attr_accessor :timeout_reboot
    attr_accessor :cmd_soft_reboot_rsh
    attr_accessor :cmd_soft_reboot_ssh
    attr_accessor :cmd_hard_reboot
    attr_accessor :cmd_very_hard_reboot
    attr_accessor :cmd_console
    attr_accessor :partition_creation_kind
    attr_accessor :partition_file
    attr_accessor :drivers
    attr_accessor :kernel_params
    attr_accessor :admin_pre_install
    attr_accessor :admin_post_install

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
      @prod_kernel = nil
      @prod_initrd = nil
      @tmp_part = nil
      @timeout_reboot = nil
      @cmd_soft_reboot_rsh = nil
      @cmd_soft_reboot_ssh = nil
      @cmd_hard_reboot = nil
      @cmd_very_hard_reboot = nil
      @cmd_console = nil
      @drivers = nil
      @kernel_params = nil
      @admin_pre_install = nil
      @admin_post_install = nil
      @partition_creation_kind = nil
      @partition_file = nil
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
      dest.prod_kernel = @prod_kernel.clone
      dest.prod_initrd = @prod_initrd.clone
      dest.tmp_part = @tmp_part.clone
      dest.timeout_reboot = @timeout_reboot
      dest.cmd_soft_reboot_rsh = @cmd_soft_reboot_rsh.clone
      dest.cmd_soft_reboot_ssh = @cmd_soft_reboot_ssh.clone
      dest.cmd_hard_reboot = @cmd_hard_reboot.clone
      dest.cmd_very_hard_reboot = @cmd_very_hard_reboot.clone
      dest.cmd_console = @cmd_console.clone
      dest.drivers = @drivers.clone if (@drivers != nil)
      dest.kernel_params = @kernel_params.clone if (@kernel_params != nil)
      dest.admin_pre_install = @admin_pre_install.clone if (@admin_pre_install != nil)
      dest.admin_post_install = @admin_post_install.clone if (@admin_post_install != nil)
      dest.partition_creation_kind = @partition_creation_kind.clone
      dest.partition_file = @partition_file.clone
    end
    
    # Duplicate a ClusterSpecificConfig instance
    #
    # Arguments
    # * dest: destination ClusterSpecificConfig instance
    # Output
    # * nothing      
    def duplicate_all(dest)
      dest.workflow_steps = @workflow_steps.clone
      dest.deploy_kernel = @deploy_kernel.clone
      dest.deploy_initrd = @deploy_initrd.clone
      dest.block_device = @block_device.clone
      dest.deploy_part = @deploy_part.clone
      dest.prod_part = @prod_part.clone
      dest.prod_kernel = @prod_kernel.clone
      dest.prod_initrd = @prod_initrd.clone
      dest.tmp_part = @tmp_part.clone
      dest.timeout_reboot = @timeout_reboot
      dest.cmd_soft_reboot_rsh = @cmd_soft_reboot_rsh.clone
      dest.cmd_soft_reboot_ssh = @cmd_soft_reboot_ssh.clone
      dest.cmd_hard_reboot = @cmd_hard_reboot.clone
      dest.cmd_very_hard_reboot = @cmd_very_hard_reboot.clone
      dest.cmd_console = @cmd_console.clone
      dest.drivers = @drivers.clone if (@drivers != nil)
      dest.kernel_params = @kernel_params.clone if (@kernel_params != nil)
      dest.admin_pre_install = @admin_pre_install.clone if (@admin_pre_install != nil)
      dest.admin_post_install = @admin_post_install.clone if (@admin_post_install != nil)
      dest.partition_creation_kind = @partition_creation_kind.clone
      dest.partition_file = @partition_file.clone
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
          (@prod_kernel == nil) || (@prod_initrd == nil) || (@tmp_part == nil) || (@workflow_steps == nil) || (@timeout_reboot == nil) ||
          (@cmd_soft_reboot_rsh == nil) || (@cmd_soft_reboot_ssh == nil) || (@cmd_hard_reboot == nil) || (@cmd_very_hard_reboot == nil) ||
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
    #                     [1] is the number of retries available for the instance
    #                     [2] is the timeout for the instance
    def get_instance
      return @array_of_instances[@current]
    end
  end
end
