# Kadeploy 3.1
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2011
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

#Kadelpoy libs
require 'automata'
require 'debug'

class Macrostep < Automata::TaskedTaskManager
  attr_reader :output, :logger, :tasks
  include Printer

  def initialize(name, idx, subidx, nodes, nsid, manager_queue, output, logger, context = {}, config = {}, params = [])
    @tasks = []
    @output = output
    super(name,idx,subidx,nodes,nsid,manager_queue,context,config,params)
    @logger = logger
    @start_time = nil
  end

  def microclass
    Microstep
  end

  def steps
    raise 'Should be reimplemented'
  end

  def load_config()
    super()
    new_tasks = tasks.dup
    offset = 0
    suboffset = 0

    addcustoms = Proc.new do |op, operations, subst, pre, post|
      operations.each do |operation|
        opname = "#{op.to_s}_#{operation[:name]}".to_sym
        timeout = 0
        timeout = operation.delete(:timeout) if operation[:timeout]
        retries = 0
        retries = operation.delete(:retries) if operation[:retries]
        if op == :custom_pre
          pre << [ opname, operation ]
        elsif op == :custom_post
          post << [ opname, operation ]
        else
          subst << [ opname, operation ]
        end
        conf_task(opname,conf_task_default())
        conf_task(opname,{ :timeout => timeout, :retries => retries })
      end
    end

    custom = Proc.new do |task,op,i,j|
      if @config[task][op]
        if j
          pres = []
          posts = []
          subst = []
          addcustoms.call(op,@config[task][op],subst,pres,posts)

          new_tasks[i+offset].insert(j+suboffset,*pres) unless pres.empty?
          suboffset += pres.size

          unless subst.empty?
            new_tasks[i+offset].delete_at(j+suboffset)
            new_tasks[i+offset].insert(j+suboffset,*subst)
            suboffset += (subst.size - 1)
          end

          new_tasks[i+offset].insert(j+suboffset+1,*posts) unless posts.empty?
          suboffset += posts.size
        else
          pres = []
          posts = []
          subst = []
          addcustoms.call(op,@config[task][op],subst,pres,posts)

          new_tasks.insert(i+offset,*pres) unless pres.empty?
          offset += pres.size

          unless subst.empty?
            new_tasks.delete_at(i+offset)
            new_tasks.insert(i+offset,*subst)
            offset += (subst.size - 1)
          end

          new_tasks.insert(i+offset+1,*posts) unless posts.empty?
          offset += posts.size
        end
      end
    end

    tasks.each_index do |i|
      if multi_task?(i,tasks)
        suboffset = 0
        tasks[i].each do |j|
          taskval = get_task(i,j)
          custom.call(taskval[0],:custom_pre,i,j)
          custom.call(taskval[0],:custom_sub,i,j)
          custom.call(taskval[0],:custom_post,i,j)
        end
      else
        taskval = get_task(i,0)
        custom.call(taskval[0],:custom_pre,i,nil)
        custom.call(taskval[0],:custom_sub,i,nil)
        custom.call(taskval[0],:custom_post,i,nil)
      end
    end
    @tasks = new_tasks
  end

  def delete_task(taskname)
    delete = lambda do |arr,index|
      if arr[index][0] == taskname
        arr.delete_at(index)
        debug(5, " * Bypassing the step #{self.class.name}-#{taskname.to_s}",nsid)
      end
    end

    tasks.each_index do |i|
      if multi_task?(i,tasks)
        tasks[i].each do |j|
          delete.call(tasks[i],j)
        end
        tasks.delete_at(i) if tasks[i].empty?
      else
        delete.call(tasks,i)
      end
    end
  end

  def load_tasks
    @tasks = steps()
    cexec = context[:execution]

    # Deploy on block device
    if cexec.block_device and !cexec.block_device.empty? \
      and (!cexec.deploy_part or cexec.deploy_part.empty?)
      delete_task(:create_partition_table)
      delete_task(:format_deploy_part)
      delete_task(:format_tmp_part)
      delete_task(:format_swap_part)
    end

    # ddgz or ddbz2 image
    if ['ddgz','ddbz2'].include?(cexec.environment.tarball["kind"])
      delete_task(:format_deploy_part)
      delete_task(:mount_deploy_part)
      delete_task(:umount_deploy_part)
      delete_task(:manage_admin_post_install)
      delete_task(:manage_user_post_install)
      delete_task(:check_kernel_files)
      delete_task(:send_key)
      delete_task(:install_bootloader)
    end

    if !cexec.key or cexec.key.empty?
      delete_task(:send_key_in_deploy_env)
      delete_task(:send_key)
    end

    delete_task(:create_partition_table) if cexec.disable_disk_partitioning

    delete_task(:format_tmp_part) unless cexec.reformat_tmp

    delete_task(:format_swap_part) \
      if context[:cluster].swap_part.nil? \
      or context[:cluster].swap_part == 'none' \
      or cexec.environment.environment_kind != 'linux'

    delete_task(:install_bootloader) \
      if context[:common].bootloader == 'chainload_pxe' \
      and cexec.disable_bootloader_install

    delete_task(:manage_admin_pre_install) \
      if cexec.environment.preinstall.nil? \
      and context[:cluster].admin_pre_install.nil?

    delete_task(:manage_admin_post_install) if context[:cluster].admin_post_install.nil?

    delete_task(:manage_user_post_install) if cexec.environment.postinstall.nil?

    delete_task(:set_vlan) if cexec.vlan.nil?

    # Do not reformat deploy partition
    if !cexec.deploy_part.nil? and cexec.deploy_part != ""
      part = cexec.deploy_part.to_i
      delete_task(:format_swap_part) if part == context[:cluster].swap_part.to_i
      delete_task(:format_tmp_part) if part == context[:cluster].tmp_part.to_i
    end
    # delete_task(:send_key) if self.superclass == SetDeploymentEnv
  end

  def create_task(idx,subidx,nodes,nsid,context)
    taskval = get_task(idx,subidx)

    microclass().new(
      taskval[0],
      idx,
      subidx,
      nodes,
      nsid,
      @queue,
      @output,
      context,
      taskval[1..-1]
    )
  end

  def break!(task,nodeset)
    debug(2,"*** Breakpoint on #{task.name.to_s} reached for #{nodeset.to_s_fold}",task.nsid)
    debug(1,"Step #{self.class.name} breakpointed",task.nsid)
    log("step#{idx+1}_duration",(Time.now.to_i-@start_time),nodeset)
  end

  def success!(task,nodeset)
    debug(1,
      "End of step #{self.class.name} after #{Time.now.to_i - @start_time}s",
      task.nsid
    )
    log("step#{idx+1}_duration",(Time.now.to_i-@start_time),nodeset)
  end

  def fail!(task,nodeset)
    debug(2,"!!! The nodes #{nodeset.to_s_fold} failed on step #{task.name.to_s}",task.nsid)
    debug(1,
      "Step #{self.class.name} failed for #{nodeset.to_s_fold} "\
      "after #{Time.now.to_i - @start_time}s",
      task.nsid
    )
    log("step#{idx+1}_duration",(Time.now.to_i-@start_time),nodeset)
  end

  def timeout!(task)
    debug(1,
      "Timeout in #{task.name} before the end of the step, "\
      "let's kill the instance",
      task.nsid
    )
    task.nodes.set_error_msg("Timeout in the #{task.name} step")
    nodes.set.each do |node|
      node.state = "KO"
      context[:config].set_node_state(node.hostname, "", "", "ko")
    end
  end

  def split!(nsid0,nsid1,ns1,nsid2,ns2)
    initnsid = Debug.prefix(context[:cluster].prefix,nsid0)
    initnsid = '[0] ' if initnsid.empty?
    debug(1,'---')
    debug(1,"Nodeset #{initnsid}split into :")
    debug(1,"  #{Debug.prefix(context[:cluster].prefix,nsid1)}#{ns1.to_s_fold}")
    debug(1,"  #{Debug.prefix(context[:cluster].prefix,nsid2)}#{ns2.to_s_fold}")
    debug(1,'---')
  end

  def start!()
    @start_time = Time.now.to_i
    debug(1,
      "Performing a #{self.class.name} step",
      nsid
    )
    log("step#{idx+1}", self.class.name,nodes)
    log("timeout_step#{idx+1}", context[:local][:timeout] || 0, nodes)
  end

  def done!()
    @start_time = nil
  end
end
