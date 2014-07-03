module Kadeploy

module Macrostep
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

    def free()
      super()
      @tasks = nil
      @output = nil
      @logger = nil
      @start_time = nil
    end

    def microclass
      ::Kadeploy::Microstep
    end

    def step_name()
      self.class.step_name
    end

    def macroname()
      if context[:local][:parent] and context[:local][:parent].class.respond_to?(:operation)
        "#{context[:local][:parent].class.operation.capitalize}[#{step_name}]"
      else
        step_name
      end
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
      to_delete = []
      delete = lambda do |arr,index|
        if arr[index][0] == taskname
          to_delete << [arr,index]
          debug(5, " * Bypassing the step #{macroname}-#{taskname.to_s}",nsid)
        end
      end

      tasks.each_index do |i|
        if multi_task?(i,tasks)
          tasks[i].each do |j|
            delete.call(tasks[i],j)
          end
        else
          delete.call(tasks,i)
        end
      end
      to_delete.each{|tmp| tmp[0].delete_at(tmp[1])}
      to_delete.clear

      # clean empty tasks
      tasks.each_index do |i|
        to_delete << [tasks,i] if tasks[i].empty?
      end
      to_delete.each{|tmp| tmp[0].delete_at(tmp[1])}
      to_delete.clear

      to_delete = nil
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
      debug(1,"Step #{macroname} breakpointed",task.nsid)
      log("step#{idx+1}_duration",(Time.now.to_i-@start_time),nodeset)
    end

    def success!(task,nodeset)
      debug(1,
        "End of step #{macroname} after #{Time.now.to_i - @start_time}s",
        task.nsid
      )
      log("step#{idx+1}_duration",(Time.now.to_i-@start_time),nodeset)
    end

    def display_fail_message(task,nodeset)
      debug(2,"!!! The nodes #{nodeset.to_s_fold} failed on step #{task.name.to_s}",task.nsid)
      debug(1,
        "Step #{macroname} failed for #{nodeset.to_s_fold} "\
        "after #{Time.now.to_i - @start_time}s",
        task.nsid
      )
    end

    def fail!(task,nodeset)
      log("step#{idx+1}_duration",(Time.now.to_i-@start_time),nodeset)
    end

    def timeout!(task)
      debug(1,"Timeout in the #{task.name} step, let's kill the instance",
        task.nsid)
      task.nodes.set_error_msg("Timeout in the #{task.name} step")
      nodes.set.each do |node|
        node.state = "KO"
        context[:states].set(node.hostname, "", "", "ko")
      end
    end

    def split!(nsid0,nsid1,ns1,nsid2,ns2)
      initnsid = Debug.prefix(context[:cluster_prefix],nsid0)
      initnsid = '[0] ' if initnsid.empty?
      debug(1,'---',nsid0)
      debug(1,"Nodeset #{initnsid}split into :",nsid0)
      debug(1,"  #{Debug.prefix(context[:cluster_prefix],nsid1)}#{ns1.to_s_fold}",nsid0)
      debug(1,"  #{Debug.prefix(context[:cluster_prefix],nsid2)}#{ns2.to_s_fold}",nsid0)
      debug(1,'---',nsid0)
    end

    def start!()
      @start_time = Time.now.to_i
      debug(1,"Performing a #{macroname} step",nsid)
      log("step#{idx+1}",step_name,nodes)
      log("timeout_step#{idx+1}", context[:local][:timeout] || 0, nodes)
    end

    def done!()
      @start_time = nil
    end

    def self.step_name()
      raise
    end

    def load_tasks
      raise
    end

    def steps
      raise 'Should be reimplemented'
    end
  end

  class Deploy < Macrostep
    def self.step_name()
      name.split('::').last.gsub(/^Deploy/,'')
    end

    def load_tasks
      @tasks = steps().dup
      cexec = context[:execution]

      # Deploy on block device
      if cexec.block_device and !cexec.block_device.empty? \
        and (!cexec.deploy_part or cexec.deploy_part.empty?)
        delete_task(:create_partition_table)
        delete_task(:format_deploy_part)
        delete_task(:format_tmp_part)
        delete_task(:format_swap_part)
      end

      delete_task(:decompress_environment) if !context[:cluster].decompress_environment and cexec.environment.image[:kind] != 'fsa'

      if ['dd','fsa'].include?(cexec.environment.image[:kind])
        delete_task(:format_deploy_part)
        # mount deploy part after send_environemnt
        delete_task(:mount_deploy_part) if self.class.superclass == DeploySetDeploymentEnv
      else
        # mount deploy part after format_deploy_part
        delete_task(:mount_deploy_part) if self.class.superclass == DeployBroadcastEnv
      end

      # The filesystem is not supported by the deployment kernel
      unless context[:cluster].deploy_supported_fs.include?(cexec.environment.filesystem)
        delete_task(:mount_deploy_part)
        delete_task(:umount_deploy_part)
        delete_task(:manage_admin_post_install)
        delete_task(:manage_user_post_install)
        delete_task(:check_kernel_files)
        delete_task(:send_key)
        delete_task(:install_bootloader)
      end

      # Multi-partitioned environment
      if cexec.environment.multipart
        delete_task(:format_tmp_part)
        delete_task(:format_swap_part)
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
        if context[:common].pxe[:local].is_a?(NetBoot::GrubPXE)  \
        or cexec.disable_bootloader_install

      delete_task(:manage_admin_pre_install) \
        if cexec.environment.preinstall.nil? \
        and context[:cluster].admin_pre_install.nil?

      delete_task(:manage_admin_post_install) if context[:cluster].admin_post_install.nil?

      delete_task(:manage_user_post_install) if cexec.environment.postinstall.nil?

      delete_task(:set_vlan) if cexec.vlan_id.nil?

      # Do not reformat deploy partition
      if !cexec.deploy_part.nil? and cexec.deploy_part != ""
        part = cexec.deploy_part.to_i
        delete_task(:format_swap_part) if part == context[:cluster].swap_part.to_i
        delete_task(:format_tmp_part) if part == context[:cluster].tmp_part.to_i
      end
    end
  end

  class Power < Macrostep
    def self.step_name()
      name.split('::').last.gsub(/^Power/,'')
    end

    def load_tasks
      @tasks = steps()
    end
  end

  class Reboot < Macrostep
    def self.step_name()
      name.split('::').last.gsub(/^Reboot/,'')
    end

    def load_tasks
      @tasks = steps()
      cexec = context[:execution]
      delete_task(:set_vlan) if cexec.vlan_id.nil?
      delete_task(:send_key_in_deploy_env) if !cexec.key or cexec.key.empty?
      delete_task(:check_nodes) if self.class == RebootRecordedEnv and cexec.deploy_part != context[:cluster].prod_part
    end
  end
end

end
