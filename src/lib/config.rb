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
  VERSION_FILE = File.join($kadeploy_config_directory, "version")
  USER = `id -nu`.chomp
  CONTACT_EMAIL = "kadeploy3-users@lists.gforge.inria.fr"

  module ConfigFile
    def file()
      raise
    end
  end

  class Config
    public

    attr_accessor :common
    attr_accessor :cluster_specific
    @opts = nil

    # Constructor of Config (used in KadeployServer)
    #
    # Arguments
    # * empty (opt): specify if an empty configuration must be generated
    # Output
    # * nothing if all is OK, otherwise raises an exception
    def initialize(empty = false)
      if not empty then
        sanity_check()

        # Common
        @common = CommonConfig.new
        res = @common.load

        begin
          @common.version = File.read(VERSION_FILE).strip
        rescue Errno::ENOENT
          raise ArgumentError.new("File not found '#{VERSION_FILE}'")
        end

        # Clusters
        @cluster_specific = ClustersConfig.new
        res = res && @cluster_specific.load(@common)

        # Commands
        res = res && CommandsConfig.new.load(@common)

        raise KadeployError.new(APIError::BAD_CONFIGURATION,nil,
          "Problem in configuration") if not res
      end
    end

    def self.dir()
      ENV['KADEPLOY_CONFIG_DIR']||'/etc/kadeploy3'
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
      node = @common.nodes.get_node_by_host(exec_specific_config.node)
      if (node == nil) then
        Debug::distant_client_error("The node #{exec_specific_config.node} does not exist", client)
        return 1
      else
        exec_specific_config.node = node
      end
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
      files = [ CommonConfig.file, ClustersConfig.file, CommandsConfig.file, VERSION_FILE ]

      files.each do |file|
        unless File.readable?(file)
          $stderr.puts "The #{file} file cannot be read"
          raise KadeployError.new(APIError::BAD_CONFIGURATION,nil,
            "Unsane configuration")
        end
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
        n = @common.nodes.get_node_by_host(host)
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
      exec_specific.environment = Environment.new
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
        opt.on("-c", "--check-destructive-tag", "Check if some nodes was deployed with an environment that have the destructive tag") {
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
end

end
