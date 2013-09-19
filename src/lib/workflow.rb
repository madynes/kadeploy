#Kadeploy libs
require 'debug'
require 'nodes'
require 'automata'
require 'config'
require 'macrostep'
require 'stepdeployenv'
require 'stepbroadcastenv'
require 'stepbootnewenv'
require 'steppower'
require 'md5'
require 'http'
require 'error'
require 'grabfile'
require 'window'

#Ruby libs
require 'thread'
require 'uri'
require 'tempfile'

module Kadeploy

module Workflow
  class Workflow < Automata::TaskManager
    include Printer
    attr_reader :nodes_brk, :nodes_ok, :nodes_ko, :tasks, :output, :logger, :errno

    def initialize(nodeset,context={})
      @tasks = []
      @errno = nil
      @output = context[:output]
      super(nodeset,context)
      @nodes_brk = Nodes::NodeSet.new
      @nodes_ok = Nodes::NodeSet.new
      @nodes_ko = Nodes::NodeSet.new
      @logger = context[:logger]
      @start_time = nil
    end

    def free()
      super()
      @tasks = nil
      @errno = nil
      @output.free if @output
      @output = nil
      #@nodes_brk.free(false) if @nodes_brk
      @nodes_brk = nil
      #@nodes_ok.free(false) if @nodes_ok
      @nodes_ok = nil
      #@nodes_ko.free(false) if @nodes_ko
      @nodes_ko = nil
      @logger.free if @logger
      @logger = nil
      @start_time = nil
    end

    def context
      @static_context
    end

    def nsid
      -1
    end

    def done?()
      super() or !@errno.nil?
    end

    def error(errno,msg='',abrt=true)
      @errno = errno
      @nodes.set_state('aborted',nil,context[:database],context[:user]) if abrt
      raise KadeployError.new(@errno,nil,msg)
    end

    def check_file(path)
      if path and !path.empty?
        kind = nil
        begin
          kind = URI.parse(path).scheme || 'local'
        rescue URI::InvalidURIError
          kind = 'local'
        end

        if kind == 'local'
          unless File.readable?(path)
            error(APIError::INVALID_FILE,"The file '#{path}' is not readable on the server")
          end
        else
          error(APIError::CACHE_ERROR,"The file '#{path}' should have been cached")
        end
      end
    end

    def check_files()
      cexec = context[:execution]
      if cexec.env
        check_file(cexec.env.tarball['file']) if cexec.env.tarball
        check_file(cexec.env.preinstall['file']) if cexec.env.preinstall
        if cexec.env.postinstall and !cexec.env.postinstall.empty?
          cexec.env.postinstall.each do |postinstall|
            check_file(cexec.env.postinstall['file'])
          end
        end
      end

      check_file(cexec.key) if cexec.key

      if cexec.custom_operations
        cexec.custom_operations[:operations].each_pair do |macro,micros|
          micros.each_pair do |micro,entries|
            entries.each do |entry|
              if entry[:action] == :send or entry[:action] == :run
                check_file(entry[:file])
              end
            end
          end
        end
      end

      if cexec.pxe and cexec.pxe[:files] and !cexec.pxe[:files].empty?
        cexec.pxe[:files].each do |pxefile|
          check_file(pxefile)
        end
      end
    end

    def load_config()
      super()
      macrosteps = load_macrosteps()

      macrosteps.each do |macro|
        macro.get_instances.each do |instance|
          instsym = instance[0].to_sym
          conf_task(instsym, {:retries => instance[1],:timeout => instance[2]})
          conf_task(instsym, {:raisable => instance[3]}) if instance.size >= 4
          conf_task(instsym, {:breakpoint => instance[4]}) if instance.size >= 5
          conf_task(instsym, {:config => instance[5]}) if instance.size >= 6
        end
      end

      if context[:execution].breakpoint
        macro,micro = context[:execution].breakpoint.split(':')
        @config[macro.to_sym][:config] = {} unless @config[macro.to_sym][:config]
        @config[macro.to_sym][:config][micro.to_sym] = {} unless @config[macro.to_sym][:config][micro.to_sym]
        @config[macro.to_sym][:config][micro.to_sym][:breakpoint] = true
      end

      check_config()
    end

    def create_task(idx,subidx,nodes,nsid,context)
      taskval = get_task(idx,subidx)

      begin
        klass = ::Kadeploy::Macrostep.const_get("#{self.class.name.split('::').last}#{taskval[0]}")
      rescue NameError
        raise "Invalid kind of Macrostep #{taskval[0]}"
      end

      klass.new(
        taskval[0],
        idx,
        subidx,
        nodes,
        nsid,
        @queue,
        @output,
        @logger,
        context,
        @config[taskval[0].to_sym][:config],
        nil
      )
    end

    def run!
      Thread.new do
        begin
          yield if block_given?
          self.start
        rescue KadeployError => ke
          error(ke.errno,ke.message)
        end
      end
    end

    def kill(dofree=true)
      super(false)
      @nodes_ok.clean()
      @nodes.linked_copy(@nodes_ko)
      free() if dofree
    end

    def start!
      check_files()

      @start_time = Time.now.to_i
      debug(0, "Launching a #{self.class.opname()} on #{@nodes.to_s_fold}")

      # Check nodes deploying
      unless context[:execution].force
        _,to_discard = @nodes.check_nodes_used(
          context[:database],
          context[:common].purge_deployment_timer
        )
        unless to_discard.empty?
          debug(0,
            "The nodes #{to_discard.to_s_fold} are already involved in "\
            "#{self.class.opname()}, let's discard them"
          )
          to_discard.set.each do |node|
            context[:states].set(node.hostname, '', '', 'discarded')
            @nodes.remove(node)
          end
        end
      end

      if @nodes.empty?
        error(APIError::NOTHING_MODIFIED,'All the nodes have been discarded ...')
      else
        @nodes.set_state(
          self.class.operation('ing'),
          (context[:execution].environment ? context[:execution].environment.id : nil),
          context[:database],
          context[:user]
        )
      end

      load_custom_operations()
    end

    def break!(task,nodeset)
      @nodes_brk.set_state(self.class.operation('ed'),nil,
        context[:database],context[:user])
      log('success', true, nodeset)
      debug(1,"Breakpoint reached for #{nodeset.to_s_fold}",task.nsid)
    end

    def success!(task,nodeset)
      @nodes_ok.set_state(self.class.operation('ed'),nil,
        context[:database],context[:user])
      log('success', true, nodeset)
      debug(1,
        "End of #{self.class.opname()} for #{nodeset.to_s_fold} "\
        "after #{Time.now.to_i - @start_time}s",
        task.nsid
      )
    end

    def fail!(task,nodeset)
      @nodes_ko.set_state(self.class.operation('_failed'),nil,
        context[:database],context[:user])
      log('success', false, nodeset)
      @logger.error(nodeset,context[:states])
      debug(1,
        "Deployment failed for #{nodeset.to_s_fold} "\
        "after #{Time.now.to_i - @start_time}s",
        task.nsid
      )
    end

    def done!()
      debug(0,
        "End of #{self.class.opname()} on cluster #{context[:cluster].name} "\
        "after #{Time.now.to_i - @start_time}s"
      )

      @logger.dump

      if context[:async] and !context[:common].async_end_of_deployment_hook.empty?
        cmd = context[:common].async_end_of_deployment_hook
        Execute[cmd.gsub('WORKFLOW_ID',context[:deploy_id])].run!.wait
      end

      nodes_ok = Nodes::NodeSet.new
      @nodes_ok.linked_copy(nodes_ok)
      @nodes_brk.linked_copy(nodes_ok)

      context[:client].generate_files(nodes_ok, @nodes_ko) if context[:client]
    end

    def retry!(task)
      log("retry_step#{task.idx+1}",nil, task.nodes, :increment => true)
    end

    def timeout!(task)
      debug(1,
        "Timeout in #{task.name} before the end of the step, "\
        "let's kill the instance",
        task.nsid
      )
      task.nodes.set_error_msg("Timeout in the #{task.name} step")
    end

    def kill!()
      log('success', false)
      @logger.dump
      @nodes.set_state('aborted', nil, context[:database], context[:user])
      debug(2," * Kill a #{self.class.opname()} instance")
      debug(0,"#{self.class.opname().capitalize} aborted by user")
    end

    private

    def load_custom_operations
      # Custom files
      if context[:execution].custom_operations
        context[:execution].custom_operations[:operations].each_pair do |macrobase,micros|
          @config.keys.select{|v| v =~ /^#{macrobase}/}.each do |macro|
            micros.each_pair do |micro,entries|
              @config[macro] = {} unless @config[macro]
              @config[macro][:config] = {} unless @config[macro][:config]
              @config[macro][:config][micro] = conf_task_default() unless @config[macro][:config][micro]

              if context[:execution].custom_operations[:overrides][macro]
                override = context[:execution].custom_operations[:overrides][macro][micro]
              else
                override = false
              end

              overriden = {}
              entries.each do |entry|
                target = nil
                if entry[:target] == :'pre-ops'
                  @config[macro][:config][micro][:custom_pre] = [] unless @config[macro][:config][micro][:custom_pre]
                  target = @config[macro][:config][micro][:custom_pre]
                elsif entry[:target] == :'post-ops'
                  @config[macro][:config][micro][:custom_post] = [] unless @config[macro][:config][micro][:custom_post]
                  target = @config[macro][:config][micro][:custom_post]
                elsif entry[:target] == :sub
                  @config[macro][:config][micro][:custom_sub] = [] unless @config[macro][:config][micro][:custom_sub]
                  target = @config[macro][:config][micro][:custom_sub]
                else
                  raise
                end

                overriden[entry[:target]] = true if target.empty?

                if !overriden[entry[:target]] and override
                  target.clear
                  overriden[entry[:target]] = true
                end

                if entry[:action] == :send
                  target << {
                    :name => entry[:name],
                    :action => :send,
                    :file => entry[:file],
                    :destination => entry[:destination],
                    :filename => entry[:filename],
                    :timeout => entry[:timeout],
                    :retries => entry[:retries],
                    :destination => entry[:destination],
                    :scattering => entry[:scattering]
                  }
                elsif entry[:action] == :exec
                  target << {
                    :name => entry[:name],
                    :action => :exec,
                    :command => entry[:command],
                    :timeout => entry[:timeout],
                    :retries => entry[:retries],
                    :scattering => entry[:scattering]
                  }
                elsif entry[:action] == :run
                  target << {
                    :name => entry[:name],
                    :action => :run,
                    :file => entry[:file],
                    :params => entry[:params],
                    :timeout => entry[:timeout],
                    :retries => entry[:retries],
                    :scattering => entry[:scattering]
                  }
                else
                  error(APIError::INVALID_FILE,'Custom operations file')
                end
              end
            end
          end
        end
      end
    end

    def self.operation(suffix='')
      raise
    end

    def load_tasks()
      raise
    end

    def check_config()
      raise
    end

  end

  class Deploy < Workflow
    def self.opname(suffix='')
      "deployment"
    end

    def self.operation(suffix='')
      "deploy#{suffix}"
    end

    def load_macrosteps()
      if context[:execution].steps and !context[:execution].steps.empty?
        context[:execution].steps
      else
        context[:cluster].workflow_steps
      end
    end

    def load_tasks()
      @tasks = [ [], [], [] ]

      macrosteps = load_macrosteps()

      # Custom preinstalls hack
      if context[:execution].environment.preinstall
        instances = macrosteps[0].get_instances
        # use same values the first instance is using
        tmp = [
          'SetDeploymentEnvUntrustedCustomPreInstall',
          *instances[0][1..-1]
        ]
        instances.clear
        instances << tmp
        debug(0,"A specific presinstall will be used with this environment")
      end

      # SetDeploymentEnv step
      macrosteps[0].get_instances.each do |instance|
        @tasks[0] << [ instance[0].to_sym ]
      end

      # BroadcastEnv step
      macrosteps[1].get_instances.each do |instance|
        @tasks[1] << [ instance[0].to_sym ]
      end

      # BootNewEnv step
      n = n = @nodes.length
      setclassical = lambda do |inst,msg|
        if inst[0] == 'BootNewEnvKexec'
          inst[0] = 'BootNewEnvClassical'
          # Should not be hardcoded
          inst[1] = 0
          inst[2] = eval("(#{context[:cluster].timeout_reboot_classical})+200").to_i
          debug(0,msg)
        end
      end
      macrosteps[2].get_instances.each do |instance|
        # Kexec hack for non-linux envs
        if (context[:execution].environment.environment_kind != 'linux')
          setclassical.call(
            instance,
            "Using classical reboot instead of kexec one with this "\
            "non-linux environment"
          )
        # The filesystem is not supported by the deployment kernel
        elsif !context[:cluster].deploy_supported_fs.include?(context[:execution].environment.filesystem)
          setclassical.call(
            instance,
            "Using classical reboot instead of kexec since the filesystem of the boot partition is not supported"
          )
        end

        @tasks[2] << [ instance[0].to_sym ]
      end

      @tasks.each do |macro|
        macro = macro[0] if macro.size == 1
      end
    end

    def check_config()
      cexec = context[:execution]
      # Deploy on block device
      if cexec.block_device and !cexec.block_device.empty? \
        and (!cexec.deploy_part or cexec.deploy_part.empty?)

        # Without a dd image
        unless cexec.environment.image[:kind] == 'dd'
          error(APIError::INVALID,"You can only deploy directly on block device when using a dd image")
        end
        # Without specifying the partition to chainload on
        if cexec.boot_part.nil?
          error(APIError::CONFLICTING_OPTIONS,"You must specify the partition to boot on when deploying directly on block device")
        end
      end

      if cexec.reformat_tmp and !context[:cluster].deploy_supported_fs.include?(cexec.reformat_tmp)
        error(APIError::CONFLICTING_OPTIONS,"The filesystem '#{cexec.reformat_tmp}' is not supported by the deployment environment")
      end

=begin
      # Deploy FSA images
      if cexec.environment.image[:kind] == 'fsa'
        # Since no bootloader is installed with FSA, we do not allow to install
        # FSA archives unless the boot method is a GRUB PXE boot
        if !context[:common].pxe[:local].is_a?(NetBoot::GrubPXE) and cexec.pxe[:profile].empty?
          debug(0,"FSA archives can only be booted if GRUB is used to boot on the hard disk or you define a custom PXE boot method")
          error(APIError::CONFLICTING_OPTIONS)
        end
      end
=end
    end
  end

  class Power < Workflow
    def self.opname(suffix='')
      "power operation"
    end

    def self.operation(suffix='')
      "power#{suffix}"
    end

    def load_macrosteps()
      if context[:execution].steps and !context[:execution].steps.empty?
        context[:execution].steps
      else
        step = nil
        case context[:execution].operation
        when :on
          step = [['On',0,0]]
        when :off
          step = [['Off',0,0]]
        when :status
          step = [['Status',0,0]]
        else
          raise
        end
        [Configuration::MacroStep.new('Power',step)]
      end
    end

    def load_tasks()
      @tasks = [[ ]]
      macrosteps = load_macrosteps()
      macrosteps[0].get_instances.each do |instance|
        @tasks[0] << [ instance[0].to_sym ]
      end
    end

    def check_config()
    end
  end
end

end
