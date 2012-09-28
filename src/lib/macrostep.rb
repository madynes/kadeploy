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

  def initialize(name, idx, subidx, nodes, manager_queue, output, logger, context = {}, params = [])
    @tasks = []
    @output = output
    super(name,idx,subidx,nodes,manager_queue,context,params)
    @logger = logger
  end

  def microclass
    Microstep
  end

  def steps
    raise 'Should be reimplemented'
  end

  def delete_task(taskname)
    delete = lambda do |arr,index|
      if arr[index][0] == taskname
        arr.delete_at(index)
        debug(4, "*** Bypassing the step #{self.class.name}-#{taskname.to_s}")
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

    delete_task(:create_partition_table) if cexec.disable_disk_partitioning

    # We do not format/mount/umount the deploy part for a dd.gz or dd.bz2 image
    if cexec.environment.tarball['kind'] != 'tgz' and cexec.environment.tarball['kind'] != 'tbz2'
      delete_task(:format_deploy_part)
      delete_task(:mount_deploy_part)
      delete_task(:umount_deploy_part)
    end

    delete_task(:format_tmp_part) unless cexec.reformat_tmp

    delete_task(:format_swap_part) \
      if cexec.swap_part.nil? or cexec.swap_part == 'none'

    delete_task(:install_bootloader) \
      if context[:common].bootloader == 'chainload_pxe' \
      and cexec.disable_bootloader_install

    delete_task(:manage_admin_pre_install) \
      if cexec.environment.preinstall.nil? \
      and context[:cluster].admin_pre_install.nil?

    delete_task(:manage_admin_post_install) \
      if cexec.environment.environment_kind == 'other' \
      or context[:cluster].admin_post_install.nil?

    delete_task(:manage_user_post_install) \
      if cexec.environment.environment_kind == 'other' \
      or cexec.environment.postinstall.nil?

    delete_task(:set_vlan) if cexec.vlan.nil?
  end

  def create_task(idx,subidx,nodes,context)
    taskval = get_task(idx,subidx)

    microclass().new(
      taskval[0],
      idx,
      subidx,
      nodes,
      @queue,
      @output,
      context,
      taskval[1..-1]
    )
  end

  def break!(task,nodeset)
    #debug(4,"<<< Raising BRK nodes #{nodeset.to_s_fold} from #{self.class.name}") if @config[task.name][:raisable]
    debug(1,"!!! Breakpoint on #{task.name.to_s} reached for #{nodeset.to_s_fold}")
  end

  def success!(task,nodeset)
    #debug(4,"<<< Raising OK nodes #{nodeset.to_s_fold} from #{self.class.name}") if @config[task.name][:raisable]
    #debug(1,"End of step #{self.class.name} for OK nodes #{nodeset.to_s_fold}")
  end

  def fail!(task,nodeset)
    #debug(4,"<<< Raising KO nodes #{nodeset.to_s_fold} from #{self.class.name}") if @config[task.name][:raisable]
    debug(1,"!!! The nodes #{nodeset.to_s_fold} failed on step #{task.name.to_s}")
  end

  def timeout!(task)
    debug(1,
      "Timeout in [#{task.name}] before the end of the step, "\
      "let's kill the instance"
    )
    task.nodes.set_error_msg("Timeout in the #{task.name} step")
    nodes.set.each do |node|
      node.state = "KO"
      context[:config].set_node_state(node.hostname, "", "", "ko")
    end
  end

  def split!(ns,ns1,ns2)
    debug(1,"Nodeset(#{ns.id}) split into :")
    debug(1,"  Nodeset(#{ns1.id}): #{ns1.to_s_fold}")
    debug(1,"  Nodeset(#{ns2.id}): #{ns2.to_s_fold}")
  end

  def start!()
    debug(1,
      "Performing a #{self.class.name} step on the nodes #{nodes.to_s_fold}"
    )
    log("step#{idx+1}", self.class.name,nodes)
    log("timeout_step#{idx+1}", context[:local][:timeout] || 0, nodes)
  end

  def done!()
    debug(1,"End of step #{self.class.name} for nodes #{nodes.to_s_fold}")
    log("step#{idx+1}_duration", context[:local][:duration], nodes)
  end
end
