# Kadeploy 3.1
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2012
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

#Kadeploy libs
require 'debug'
require 'nodes'
require 'automata'
require 'config'
require 'cache'
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

class Workflow < TaskManager
  include Printer
  attr_reader :nodes_brk, :nodes_ok, :nodes_ko, :tasks, :output, :logger, :errno

  def initialize(nodeset,context={})
    super(nodeset,context)
    @nodes_brk = Nodes::NodeSet.new
    @nodes_ok = Nodes::NodeSet.new
    @nodes_ko = Nodes::NodeSet.new
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
      context[:syslock]
    )

    @logger = Debug::Logger.new(
      nodes,
      context[:config],
      context[:database],
      context[:execution].true_user,
      context[:deploy_id],
      Time.now,
      "#{context[:execution].environment.name}:#{context[:execution].environment.version.to_s}",
      context[:execution].load_env_kind == "file",
      context[:syslock]
    )
  end

  def error(errno,abrt=true)
    @errno = errno
    @nodes.set_deployment_state('aborted',nil,context[:database],'') if abrt
    debug(0, "Cannot run the deployment")
    raise KadeployError.new(@errno)
  end

  def load_tasks()
    macrosteps = context[:execution].steps || context[:cluster].workflow_steps

    # Custom preinstalls hack
    if context[:execution].environment.preinstall
      instances = macrosteps[0].get_instances
      # use same values the first instance is using
      tmp = [
        'SetDeploymentEnvUntrustedCustomPreInstall',
        instances[0][1],
        instances[0][2],
      ]
      instances.clear
      instances << tmp
      debug(0,"A specific presinstall will be used with this environment")
    end


    # SetDeploymentEnv step
    macrosteps[0].get_instances.each do |instance|
      @tasks << [ instance[0].to_sym ]
    end

    # BroadcastEnv step
    macrosteps[1].get_instances.each do |instance|
      @tasks << [ instance[0].to_sym ]
    end

    # BootNewEnv step
    macrosteps[2].get_instances.each do |instance|
      # Kexec hack for non-linux envs
      if (context[:execution].environment.environment_kind != 'linux')
        if instance[0] == 'BootNewEnvKexec'
          instance[0] = 'BootNewEnvClassical'
          # Should not be hardcoded
          instance[1] = 2,
          instance[2] = "(#{context[:cluster].timeout_reboot_classical})+200"
          debug(0,
            "Using classical reboot instead of kexec one with this "\
            "non-linux environment"
          )
        end
      end

      @tasks << [ instance[0].to_sym ]
    end
  end

  def load_config()
    context[:cluster].workflow_steps.each do |macro|
      macro.get_instances.each do |instance|
        conf_task(instance[0].to_sym, {
          :retries => instance[1],
          :timeout => instance[2],
        })
      end
    end

    if context[:execution].breakpoint_on_microstep
      macro,micro = context[:execution].breakpoint_on_microstep.split(':')
      conf_task(macro.to_sym, {
        :config => {
          micro.to_sym => {
            :breakpoint => true
          }
        }
      })
    end
  end

=begin
  def load_context(config,rebootw,checkw)
    @static_context.merge({
      :deploy_id => deploy_id,
      :database => db,
      :client => client,
      :syslock => syslock,
      :dblock => dblock,
      :config => config
      :common => config.common,
      :cluster => nil,
      :cluster => config.cluster_specific[task.nodes.set.first.cluster]
      :execution => config.exec_specific,
      :windows => {
        :reboot => rebootw,
        :check => checkw,
      }
    })
  end


  @nodes_ko.group_by_cluster.each_pair { |cluster, set|
    @output.verbosel(0, "Nodes not correctly deployed on cluster #{cluster}")
    @output.verbosel(0, set.to_s(false, true, "\n"))
  }
  @client.generate_files(@nodes_ok, @nodes_ko) if @client != nil
  Cache::remove_files(@config.common.kadeploy_cache_dir, /#{@config.exec_specific.prefix_in_cache}/, @output) if @config.exec_specific.load_env_kind == "file"
  @logger.dump


  if ((@async_deployment) && (@config.common.async_end_of_deployment_hook != "")) then
    tmp = cmd = @config.common.async_end_of_deployment_hook.clone
    while (tmp.sub!("WORKFLOW_ID", @deploy_id) != nil)  do
      cmd = tmp
    end
    system(cmd)
  end
}
=end

  def create_task(idx,subidx,nodes,context)
    taskval = get_task(idx,subidx)
    taskconf = @config[taskval[0].to_sym][:config]

    begin
      klass = Module.const_get(taskval[0].to_s)
    rescue NameError
      raise "Invalid kind of Macrostep #{taskval[0]}"
    end

    ret << klass.new(
      taskval[0],
      idx,
      subidx,
      set,
      @queue,
      context,
      nil
    ).config(taskconf)
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

  def kill
    super()
    @nodes_ok.clean()
    @nodes.linked_copy(@nodes_ko)
  end

  def run!
    Thread.new { self.run }
  end

  def start!
    debug(0, "Launching a deployment ...")
    context[:dblock].lock

    # Check nodes deploying
    unless context[:execution].ignore_nodes_deploying
      nothing,to_discard = @nodes.check_nodes_in_deployment(
        context[:database],
        context[:common].purge_deployment_timer
      )
      unless to_discard.empty?
        debug(0,
          "The nodes #{nodes_to_discard.to_s} are already involved in "\
          "deployment, let's discard them"
        )
        to_discard.each do |node|
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

    # Set the prefix of the files in the cache
    if context[:execution].load_env_kind == 'file'
      context[:execution].prefix_in_cache =
        "e-anon-#{context[:execution].true_user}-#{Time.now.to_i}--"
    else
      context[:execution].prefix_in_cache =
        "e-#{context[:execution].environment.id}--"
    end

    grab_user_files() if !context[:common].kadeploy_disable_cache
  end

  def break!(task,nodeset)
    debug(4,"<<< Add #{nodeset.to_s_fold} from #{task.name} to BRK nodeset")
  end

  def success!(task,nodeset)
    @logger.set('success', true, nodeset)
    debug(4,"<<< Add #{nodeset.to_s_fold} from #{task.name} to OK nodeset")
  end

  def fail!(task,nodeset)
    @logger.set('success', false, nodeset)
    @logger.error(nodeset)
    debug(4,"<<< Add #{nodeset.to_s_fold} from #{task.name} to KO nodeset")
  end

  def done!()
    context[:dblock].synchronize do
      @nodes_ok.set_deployment_state('deployed',nil,context[:database],'')
      @nodes_brk.set_deployment_state('deployed',nil,context[:database],'')
      @nodes_ko.set_deployment_state('deploy_failed',nil,context[:database],'')
    end
    @logger.dump
    if context[:async] and !context[:common].async_end_of_deployment_hook.empty?
      cmd = context[:common].async_end_of_deployment_hook
      Execute[cmd.gsub('WORKFLOW_ID',context[:deploy_id])].run!.wait
    end
    context[:client].generate_files(@nodes_ok, @nodes_ko) if context[:client]
  end

  def retry!(task)
    log(task.nodes, "retry_step#{task.idx+1}",nil, :increment => true)
  end

  def timeout!(task)
    debug(1,
      "Timeout in [#{task.name}] before the end of the step, "\
      "let's kill the instance"
    )
    task.nodes.set_error_msg("Timeout in the #{task.name} step")
  end

  def split!(ns,ns1,ns2)
    debug(1,"Nodeset(#{ns.id}) split into :")
    debug(1,"  Nodeset(#{ns1.id}): #{ns1.to_s_fold}")
    debug(1,"  Nodeset(#{ns2.id}): #{ns2.to_s_fold}")
  end

  def kill!()
    log('success', false)
    @logger.dump
    @nodes.set_deployment_state('aborted', nil, context[:database], '')
    debug(2,"*** Kill a #{self.class.name} instance")
    debug(0, 'Deployment aborted by user')
  end

  private

  def grab_file(gfm,remotepath,prefix,filetag,errno,opts={})
    return unless remotepath

    cachedir,cachesize = nil
    case opts[:cache]
      when :kernels
        cachedir = File.join(
          context[:common].pxe_repository,
          context[:common].pxe_repository_kernels
        )
        cachesize = context[:common].pxe_repository_kernels_max_size
      #when :kadeploy
      else
        cachedir = context[:common].kadeploy_cache_dir,
        cachesize = context[:common].kadeploy_cache_size,
    end

    localpath = File.join(cachedir, "#{prefix}#{File.basename(remotepath)}")

    begin
      res = nil

      if opts[:caching]
        res = gfm.grab_file(
          remotepath,
          localpath,
          opts[:md5],
          filetag,
          prefix,
          cachedir,
          cachesize,
          context[:async]
        )
      else
        res = gfm.grab_file_without_caching(
          remotepath,
          localpath,
          filetag,
          prefix,
          cachedir,
          cachesize,
          context[:async]
        )
      end

      if opts[:maxsize]
        if (File.size(localfile) / 1024**2) > opts[:maxsize]
          debug(0,
            "The #{filetag} file #{remotepath} is too big "\
            "(#{opts[:maxsize]} MB is the maximum size allowed)"
          )
          File.delete(localfile)
          error(opts[:error_maxsize])
        end
      end

      error(errno) unless res
    rescue TempfileException
      error(FetchFileError::TEMPFILE_CANNOT_BE_CREATED_IN_CACHE)
    rescue MoveException
      error(FetchFileError::FILE_CANNOT_BE_MOVED_IN_CACHE)
    end
    remotepath = localpath if !opts[:noaffect] and localpath
  end

  def grab_user_files()
    env_prefix = context[:execution].prefix_in_cache
    user_prefix = "u-#{context[:execution].true_user}--"

    gfm = GrabFileManager.new(
      context[:config], @output,
      context[:client], context[:database]
    )

    # Env tarball
    file = context[:execution].environment.tarball
    grab_file(
      gfm, file['file'], env_prefix, 'tarball',
      FetchFileError::INVALID_ENVIRONMENT_TARBALL,
      :md5 => file['md5'], :caching => true
    )

    # SSH key file
    file = context[:execution].key
    grab_file(
      gfm, file, user_prefix, 'key',
      FetchFileError::INVALID_KEY, :caching => false
    )

    # Preinstall archive
    file = context[:execution].environment.preinstall
    grab_file(
      gfm, file['file'], env_prefix, 'preinstall',
      FetchFileError::INVALID_PREINSTALL,
      :md5 => file['md5'], :caching => true,
      :maxsize => context[:common].max_preinstall_size,
      :error_maxsize => FetchFileError::PREINSTALL_TOO_BIG
    )

    # Postinstall archive
    file = context[:execution].environment.postinstall
    grab_file(
      gfm, file['file'], env_prefix, 'postinstall',
      FetchFileError::INVALID_POSTINSTALL,
      :md5 => file['md5'], :caching => true,
      :maxsize => context[:common].max_postinstall_size,
      :error_maxsize => FetchFileError::POSTINSTALL_TOO_BIG
    )

    # Custom files
    if context[:execution].custom_operations
      context[:execution].custom_operations.each_pair do |macro,micros|
        micros.each_pair do |micro,entry|
          if entry[0] == 'send'
            grab_file(
              gfm, entry[1], user_prefix, 'custom_file',
              FetchFileError::INVALID_CUSTOM_FILE, :caching => false
            )
          end
        end
      end
    end

    # Custom PXE files
    if context[:execution].pxe_profile_msg != ''
      unless context[:execution].pxe_upload_files.empty?
        context[:execution].pxe_upload_files.each do |pxefile|
          grab_file(
            gfm, pxefile, "pxe-#{context[:execution].true_user}--", 'pxe_file',
            FetchFileError::INVALID_PXE_FILE, :caching => false,
            :cache => :kernels, :noaffect => true
          )
      end
    end
  end
end
