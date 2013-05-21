# Kadeploy 3.1
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2012
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

#Kadeploy libs
require 'debug'
require 'nodes'
require 'automata'
require 'config'
require 'macrostep'
require 'stepdeployenv'
require 'stepbroadcastenv'
require 'stepbootnewenv'
require 'md5'
require 'http'
require 'error'
require 'grabfile'
require 'window'

#Ruby libs
require 'thread'
require 'uri'
require 'tempfile'

class Workflow < Automata::TaskManager
  include Printer
  attr_reader :nodes_brk, :nodes_ok, :nodes_ko, :tasks, :output, :logger, :errno

  def initialize(nodeset,context={})
    @tasks = []
    @errno = nil
    @output = Debug::OutputControl.new(
      context[:execution].verbose_level || context[:common].verbose_level,
      context[:execution].debug,
      context[:client],
      context[:execution].true_user,
      context[:deploy_id],
      context[:common].dbg_to_syslog,
      context[:common].dbg_to_syslog_level,
      context[:syslock],
      context[:cluster].prefix
    )
    super(nodeset,context)
    @nodes_brk = Nodes::NodeSet.new
    @nodes_ok = Nodes::NodeSet.new
    @nodes_ko = Nodes::NodeSet.new

    @logger = Debug::Logger.new(
      nodeset,
      context[:config],
      context[:database],
      context[:execution].true_user,
      context[:deploy_id],
      Time.now,
      "#{context[:execution].environment.name}:#{context[:execution].environment.version.to_s}",
      context[:execution].load_env_kind == "file",
      context[:syslock]
    )
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

  def error(errno,abrt=true)
    @errno = errno
    @nodes.set_deployment_state('aborted',nil,context[:database],'') if abrt
    raise KadeployError.new(@errno,context)
  end

  def load_tasks()
    @tasks = [ [], [], [] ]

    macrosteps = nil
    if context[:execution].steps and !context[:execution].steps.empty?
      macrosteps = context[:execution].steps
    else
      macrosteps = context[:cluster].workflow_steps
    end

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
          debug(0,"The file '#{path}' is not readable on the server")
          error(FetchFileError::FILE_CANNOT_BE_MOVED_IN_CACHE)
        end
      else
        debug(0,"The file '#{path}' should have been cached")
        error(FetchFileError::FILE_CANNOT_BE_MOVED_IN_CACHE)
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

    if cexec.pxe_upload_files and !cexec.pxe_upload_files.empty?
      cexec.pxe_upload_files.each do |pxefile|
        check_file(pxefile)
      end
    end
  end

  def check_config()
    cexec = context[:execution]
    # Deploy on block device
    if cexec.block_device and !cexec.block_device.empty? \
      and (!cexec.deploy_part or cexec.deploy_part.empty?)

      # Without a dd image
      unless cexec.environment.image[:kind] == 'dd'
        debug(0,"You can only deploy directly on block device when using a dd image")
        error(KadeployAsyncError::CONFLICTING_OPTIONS)
      end
      # Without specifying the partition to chainload on
      if cexec.boot_part.nil?
        debug(0,"You must specify the partition to boot on when deploying directly on block device")
        error(KadeployAsyncError::CONFLICTING_OPTIONS)
      end
    end

    if cexec.reformat_tmp and !context[:cluster].deploy_supported_fs.include?(cexec.reformat_tmp_fstype)
      debug(0,"The filesystem '#{cexec.reformat_tmp_fstype}' is not supported by the deployment environment")
      error(KadeployAsyncError::CONFLICTING_OPTIONS)
    end

=begin
    # Deploy FSA images
    if cexec.environment.image[:kind] == 'fsa'
      # Since no bootloader is installed with FSA, we do not allow to install
      # FSA archives unless the boot method is a GRUB PXE boot
      if !context[:common].pxe[:local].is_a?(NetBoot::GrubPXE) and cexec.pxe_profile_msg.empty?
        debug(0,"FSA archives can only be booted if GRUB is used to boot on the hard disk or you define a custom PXE boot method")
        error(KadeployAsyncError::CONFLICTING_OPTIONS)
      end
    end
=end
  end

  def load_config()
    super()
    macrosteps = nil
    if context[:execution].steps and !context[:execution].steps.empty?
      macrosteps = context[:execution].steps
    else
      macrosteps = context[:cluster].workflow_steps
    end

    macrosteps.each do |macro|
      macro.get_instances.each do |instance|
        instsym = instance[0].to_sym
        conf_task(instsym, {:retries => instance[1],:timeout => instance[2]})
        conf_task(instsym, {:raisable => instance[3]}) if instance.size >= 4
        conf_task(instsym, {:breakpoint => instance[4]}) if instance.size >= 5
        conf_task(instsym, {:config => instance[5]}) if instance.size >= 6
      end
    end

    if context[:execution].breakpoint_on_microstep != ''
      macro,micro = context[:execution].breakpoint_on_microstep.split(':')
      @config[macro.to_sym][:config] = {} unless @config[macro.to_sym][:config]
      @config[macro.to_sym][:config][micro.to_sym] = {} unless @config[macro.to_sym][:config][micro.to_sym]
      @config[macro.to_sym][:config][micro.to_sym][:breakpoint] = true
    end

    check_config()
  end

  def create_task(idx,subidx,nodes,nsid,context)
    taskval = get_task(idx,subidx)

    begin
      klass = Module.const_get(taskval[0].to_s)
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

  def state
    {
      'user' => context[:execution].true_user,
      'deploy_id' => context[:deploy_id],
      'environment_name' => context[:execution].environment.name,
      'environment_version' => context[:execution].environment.version,
      'environment_user' => context[:execution].user,
      'anonymous_environment' => (context[:execution].load_env_kind == 'file'),
      'nodes' => context[:execution].nodes_state,
    }
  end

  def run!
    Thread.new do
      begin
        yield if block_given?
        self.start
      rescue KadeployError => ke
        error(ke.errno)
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
    debug(0, "Launching a deployment on #{@nodes.to_s_fold}")
    context[:dblock].lock

    # Check nodes deploying
    unless context[:execution].ignore_nodes_deploying
      _,to_discard = @nodes.check_nodes_in_deployment(
        context[:database],
        context[:common].purge_deployment_timer
      )
      unless to_discard.empty?
        debug(0,
          "The nodes #{to_discard.to_s_fold} are already involved in "\
          "deployment, let's discard them"
        )
        to_discard.set.each do |node|
          context[:config].set_node_state(node.hostname, '', '', 'discarded')
          @nodes.remove(node)
        end
      end
    end

    if @nodes.empty?
      debug(0, 'All the nodes have been discarded ...')
      context[:dblock].unlock
      error(KadeployAsyncError::NODES_DISCARDED,false)
    else
      @nodes.set_deployment_state(
        'deploying',
        (context[:execution].load_env_kind == 'file' ?
          -1 : context[:execution].environment.id),
        context[:database],
        context[:execution].true_user
      )
      context[:dblock].unlock
    end

    load_custom_operations()
  end

  def break!(task,nodeset)
    context[:dblock].synchronize do
      @nodes_brk.set_deployment_state('deployed',nil,context[:database],'')
    end
    debug(1,"Breakpoint reached for #{nodeset.to_s_fold}",task.nsid)
  end

  def success!(task,nodeset)
    context[:dblock].synchronize do
      @nodes_ok.set_deployment_state('deployed',nil,context[:database],'')
    end
    @logger.set('success', true, nodeset)
    debug(1,
      "End of deployment for #{nodeset.to_s_fold} "\
      "after #{Time.now.to_i - @start_time}s",
      task.nsid
    )
  end

  def fail!(task,nodeset)
    context[:dblock].synchronize do
      @nodes_ko.set_deployment_state('deploy_failed',nil,context[:database],'')
    end
    @logger.set('success', false, nodeset)
    @logger.error(nodeset)
    debug(1,
      "Deployment failed for #{nodeset.to_s_fold} "\
      "after #{Time.now.to_i - @start_time}s",
      task.nsid
    )
  end

  def done!()
    debug(0,
      "End of deployment on cluster #{context[:cluster].name} "\
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
    @nodes.set_deployment_state('aborted', nil, context[:database], '')
    debug(2," * Kill a #{self.class.name} instance")
    debug(0,'Deployment aborted by user')
  end

  private

  def load_custom_operations
    # Custom files
    if context[:execution].custom_operations
      context[:execution].custom_operations[:operations].each_pair do |macro,micros|
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
            else
              @config[macro][:config][micro][:custom_sub] = [] unless @config[macro][:config][micro][:custom_sub]
              target = @config[macro][:config][micro][:custom_sub]
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
              error(FetchFileError::INVALID_CUSTOM_FILE)
            end
          end
        end
      end
    end
  end
end
