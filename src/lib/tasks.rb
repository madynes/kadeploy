require 'timeout'

require 'nodes'

class Task

  def run
    raise 'Should be reimplemented'
  end

  # ! do not use it in your run()
  def nodes()
    raise 'Should be reimplemented'
  end

  def nodes_ok()
    raise 'Should be reimplemented'
  end

  def nodes_ko()
    raise 'Should be reimplemented'
  end

  def idx()
    raise 'Should be reimplemented'
  end

  def subidx()
    raise 'Should be reimplemented'
  end

  def mqueue()
    raise 'Should be reimplemented'
  end

  def retries()
    raise 'Should be reimplemented'
  end

  def raise_nodes(nodeset,status)
    tmpnodeset = Nodes::NodeSet.new
    nodeset.move(tmpnodeset)

    mqueue().push({ :task => self, :status => status, :nodes => tmpnodeset})
  end

  def clean_nodes(nodeset)
    nodeset.set.each do |node|
      nodes().remove(node)
    end
  end
end

class QueueTask
  include Task

  attr_reader :name, :nodes, :idx, :subidx, :nodes_ok, :nodes_ko, :retries, :mqueue

  def initialize(name, idx, subidx, nodes, manager_queue, retries = 0, params = [])
    @name = name.to_sym
    @nodes = nodes
    @idx = idx
    @subidx = subidx
    @mqueue = manager_queue
    @retries = retries
    @params = params

    @nodes_ok = Nodes::NodeSet.new
    @nodes_ok.id = @nodes.id
    @nodes_ko = Nodes::NodeSet.new
    @nodes_ko.id = @nodes.id
  end
end

class TaskManager
  def initialize(nodeset)
    @config = {}
    @queue = Queue.new
    @threads = {}
    @nodes = nodeset #all nodes
    @complete_nodes = Nodes::NodeSet.new(@nodes.id)

    @queue.push({ :nodes => @nodes })
  end

  def load_config()
    raise 'Should be reimplemented'
  end

  def create_task(idx,subidx,nodes,retries)
    raise 'Should be reimplemented'
  end

  def tasks()
    raise 'Should be reimplemented'
  end

  def conf_task(taskname, opts)
    if opts and opts.is_a?(Hash)
      @config[taskname.to_sym] = opts
    else
      @config[taskname.to_sym] = {}
    end
  end

  def run_task(task)
    thr = Thread.new { task.run }

    timeout = @config[task.name][:timeout]
    success = true

    if timeout
      sleep(timeout)
      if thr.alive?
        thr.kill
        success = false
      end
    end

    success = success && thr.join

    if success
      unless task.nodes_ok.empty?
        @queue.push({ :task => task, :status => 'OK', :nodes => task.nodes_ok})
      end

      unless task.nodes_ko.empty?
        @queue.push({ :task => task, :status => 'KO', :nodes => task.nodes_ko})
      end
    else
      @queue.push({ :task => task, :status => 'KO', :nodes => task.nodes})
    end
  end

  def split_nodeset(startns,ns1,ns2)
    #nodesetids
  end

  def done_task(task,nodeset)
    @done_nodes.add(nodeset)
  end

  def success_task(task,nodeset)
    unless task.nodes.equals?(nodeset)
      tmpset = task.nodes.diff(nodeset)
      split_nodeset(task.nodes,nodeset,tmpset)
    end

    task.clean_nodes(nodeset)
    done_task(task,nodeset)
  end

  def fail_task(task,nodeset)
    unless task.nodes.equals?(nodeset)
      tmpset = task.nodes.diff(nodeset)
      split_nodeset(task.nodes,nodeset,tmpset)
    end

    task.clean_nodes(nodeset)
    done_task(task,nodeset)
  end

  def get_task(idx,subidx)
    ret = nil
    tasks = tasks()

    if tasks[idx].is_a?(Array)
      ret = tasks[idx][subidx]
    else
      ret = tasks[idx]
    end

    return ret
  end

  def start()
    @done_nodes.free()

    until (@done_nodes.equals?(@all_nodes))
      query = @queue.pop

      @threads.each_values do |thread|
        thread.join unless thread.alive?
      end

      next if !query[:nodes] or query[:nodes].empty?

      curtask = query[:task]
      newtask = {
        :idx => 0,
        :subidx => 0,
        :retries => 0,
      }
      continue = true

      if query[:status] and curtask
        if query[:status] == 'OK'
          if (curtask.idx + 1) < tasks().length
            newtask[:idx] = curtask.idx + 1
          else
            success_task(curtask,query[:nodes])
            continue = false
          end
        elsif query[:status] == 'KO'
          if curtask.retries < @config[curtask.name][:retries]
            newtask[:idx] = curtask.idx
            newtask[:subidx] = curtask.subidx
            newtask[:retries] = curtask.retries + 1
          else
            tasks = tasks()
            if tasks[idx].is_a?(Array) and curtask.subidx < (tasks[idx].size - 1)
              newtask[:idx] = curtask.idx
              newtask[:subidx] = curtask.subidx + 1
            else
              fail_task(curtask,query[:nodes])
              continue = false
            end
          end
        end
      end

      if continue
        task = create_task(
          newtask[:idx],
          newtask[:subidx],
          query[:nodes],
          newtask[:retries]
        )

        @threads[task] = Thread.new { run_task(task) }
      end
    end
  end

  def kill()
    @threads.each do |thread|
      thread.kill
      thread.join
    end
    @done_nodes.free()
  end
end

class TaskedTaskManager
  include Task

  attr_reader :name, :nodes, :idx, :subidx, :nodes_ok, :nodes_ko, :retries, :mqueue

  def initialize(name, idx, subidx, nodes, manager_queue, retries = 0, params = [])
    super(nodes)
    @name = name.to_sym
    @idx = idx
    @subidx = subidx
    @mqueue = manager_queue
    @retries = retries
    @params = params

    @nodes_ok = Nodes::NodeSet.new
    @nodes_ok.id = @nodes.id
    @nodes_ko = Nodes::NodeSet.new
    @nodes_ko.id = @nodes.id
  end

  def success_task(task,nodeset)
    super(task,nodeset)
    raise_nodes(nodeset,'OK')
  end

  def fail_task(task,nodeset)
    super(task,nodeset)
    raise_nodes(nodeset,'KO')
  end
end


# Now the implementation in Kadeploy

class Workflow < TaskManager
  def load_config()
    raise 'Should be reimplemented'
  end

  def tasks()
    # [
    #   [
    #     [ :SetDeployEnvKexec ],
    #     [ :SetDeployEnvUntrusted ]
    #   ],
    #   [ :BroadcastEnvKastafior ],
    #   [ :BootNewEnvHardReboot ]
    # ]
    raise 'Should be reimplemented'
  end

  def create_task(idx,subidx,nodes,retries)
    taskval = get_task(idx,subidx)

    begin
      klass = self.class_eval(taskval[0])
    rescue NameError
      raise "Invalid kind of step value for the new environment boot step"
    end

    Macrostep.new(
      taskval[0],
      idx,
      subidx,
      nodes,
      @queue,
      retries,
      nil,
    )
  end
end

class Macrostep < TaskedTaskManager
  def run()
    start()
    return true
  end

  def load_config()
    raise 'Should be reimplemented'
  end

  def create_task(idx,subidx,nodes,retries)
    taskval = get_task(idx,subidx)

    Microstep.new(
      taskval[0],
      idx,
      subidx,
      nodes,
      @queue,
      retries,
      taskval[1..-1],
    )
  end

  ## to be defined in each macrostep class
  # def tasks()
  #   [
  #     [ :switch_pxe, 'deploy_to_deployed_env' ],
  #     [ :umount_deploy_part ],
  #     [ :set_vlan ],
  #     [
  #       [ :kexec, ... ],
  #       [ :reboot, 'soft' ]
  #     ],
  #     [ :wait_reboot, 'user', true ]
  #   ]
  # end
end

class Microstep < QueueTask
  def initialize()
    #...
  end

  def run()
    send(@name,@params)
  end

  # ...
  # microstep methods
  # ...
end
