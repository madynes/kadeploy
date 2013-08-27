require 'config'
require 'configparser'

module Kadeploy

module Configuration
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
    attr_accessor :cmd_sendenv
    attr_accessor :decompress_environment
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
                  @cmd_soft_reboot = cmd
                when 'hard'
                  @cmd_hard_reboot = cmd
                when 'very_hard'
                  @cmd_very_hard_reboot = cmd
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
                  @cmd_soft_power_on = cmd
                when 'hard'
                  @cmd_hard_power_on = cmd
                when 'very_hard'
                  @cmd_very_hard_power_on = cmd
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
                  @cmd_soft_power_off = cmd
                when 'hard'
                  @cmd_hard_power_off = cmd
                when 'very_hard'
                  @cmd_very_hard_power_off = cmd
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
                klass.ancestors.include?(Macrostep.const_get("Kadeploy#{macroname}"))
              } unless macroname.empty?
              insts.collect!{ |klass| klass.name.sub(/^Kadeploy::Macrostep::Kadeploy#{macroname}/,'') }
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

      return true
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
      dest.cmd_sendenv = @cmd_sendenv.clone if (@cmd_sendenv != nil)
      dest.decompress_environment = @decompress_environment
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
      dest.cmd_sendenv = @cmd_sendenv.clone if (@cmd_sendenv != nil)
      dest.decompress_environment = @decompress_environment
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
