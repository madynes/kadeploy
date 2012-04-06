require 'thread'
require 'timeout'

require 'nodes'

Thread::abort_on_exception = true

TIMING = true

@@tstart = Time.now

def debug(msg)
  prefix = "[#{sprintf("%.3f",Time.now - @@tstart)}] " if TIMING
  #puts "#{prefix}#{self.class.name}:\t#{msg}"
  puts "#{prefix} #{msg}"
end

module Nodes
  class NodeSet
    @@ids = 0

    def self.newid
      @@ids += 1
    end

    def equals?(sub)
      ret = true

      @set.each do |node|
        if (sub.get_node_by_host(node.hostname) == nil) then
          ret = false
          break
        end
      end

      if ret
        sub.set.each do |node|
          if (get_node_by_host(node.hostname) == nil) then
            ret = false
            break
          end
        end
      end

      return ret
    end

    def diff(sub)
      dest = NodeSet.new
      @set.each { |node|
        if (sub.get_node_by_host(node.hostname) == nil) then
          dest.push(node)
        end
      }
      return dest
    end

=begin
    def diff(sub)
      dest = NodeSet.new
      @set.each { |node|
        if (sub.get_node_by_host(node.hostname) == nil) then
          dest.push(node.dup)
        end
      }
      sub.set.each { |node|
        if (get_node_by_host(node.hostname) == nil) and !dest.set.include?(node) then
          dest.push(node.dup)
        end
      }
      return dest
    end
=end

    def clean()
      @set.clear()
    end
  end
end

module Task

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

  def context()
    raise 'Should be reimplemented'
  end

  def mutex()
    raise 'Should be reimplemented'
  end

  def raise_nodes(nodeset,status)
    tmpnodeset = Nodes::NodeSet.new(nodeset.id)
    nodeset.move(tmpnodeset)

    #debug("RAISE #{status} #{tmpnodeset.to_s_fold}")
    mqueue().push({ :task => self, :status => status, :nodes => tmpnodeset})
  end

  def clean_nodes(nodeset)
    if nodeset == nodes()
      nodes().clean()
    else
      nodeset.set.each do |node|
        nodes().remove(node)
      end
    end
  end
end

class QueueTask
  include Task

  attr_reader :name, :nodes, :idx, :subidx, :nodes_ok, :nodes_ko, :context, :mqueue, :mutex

  def initialize(name, idx, subidx, nodes, manager_queue, context = {}, params = [])
    @name = name.to_sym
    @nodes = nodes
    @idx = idx
    @subidx = subidx
    @mqueue = manager_queue
    @context = context
    @params = params
    @mutex = Mutex.new

    @nodes_ok = Nodes::NodeSet.new(@nodes.id)
    @nodes_ko = Nodes::NodeSet.new(@nodes.id)
  end
end

class TaskManager
  TIMER_CKECK_PITCH = 0.5
  QUEUE_CKECK_PITCH = 0.1

  def initialize(nodeset)
    @config = {}
    @queue = Queue.new
    @threads = {}
    @nodes = nodeset #all nodes
    @nodes_done = Nodes::NodeSet.new(@nodes.id)

    nodeset = Nodes::NodeSet.new
    @nodes.linked_copy(nodeset)
    @queue.push({ :nodes => nodeset })
  end

  def load_config()
    tasks = tasks()

    proc_init = Proc.new do |taskname|
      @config[taskname.to_sym] = conf_task_default()
    end

    tasks.size.times do |idx|
      if multi_task?(idx,tasks)
        tasks[idx].size.times do |subidx|
          proc_init.call(tasks[idx][subidx][0])
        end
      else
        proc_init.call(tasks[idx][0])
      end
    end
  end

  def create_task(idx,subidx,nodes,context)
    raise 'Should be reimplemented'
  end

  def tasks()
    raise 'Should be reimplemented'
  end

  def conf_task_default()
    {
      :timeout => 0,
      :retries => 0,
      :raisable => true,
    }
  end

  def conf_task(taskname, opts)
    if opts and opts.is_a?(Hash)
      if @config[taskname.to_sym]
        @config[taskname.to_sym].merge!(opts)
      else
        @config[taskname.to_sym] = opts
      end
    end
  end

  def done_task(task,nodeset)
    @nodes_done.add(nodeset)
  end

  def success_task(task,nodeset)
    #debug("SUCCESS #{nodeset.to_s_fold}")
    done_task(task,nodeset)
  end

  def fail_task(task,nodeset)
    #debug("FAIL #{nodeset.to_s_fold}")
    done_task(task,nodeset)
  end

  def get_task(idx,subidx)
    ret = nil
    tasks = tasks()

    if multi_task?(idx,tasks)
      ret = tasks[idx][subidx]
    else
      ret = tasks[idx]
    end

    return ret
  end

  def multi_task?(idx,tasks=nil)
    tasks = tasks() unless tasks

    tasks[idx][0].is_a?(Array)
  end

  def split_nodeset(startns,newns)
    tmpns = startns.diff(newns)
    tmpns.id = Nodes::NodeSet.newid
    newns.id = Nodes::NodeSet.newid

    ## Get the right nodeset
    #allns = Nodes::NodeSet.new(startns.id)
    #tmpns.linked_copy(allns)
    #newns.linked_copy(allns)

    debug(">-< Nodeset(#{startns.id}) split into :")
    debug(">-<   Nodeset(#{tmpns.id}): #{tmpns.to_s_fold}")
    debug(">-<   Nodeset(#{newns.id}): #{newns.to_s_fold}")

    startns.id = tmpns.id
  end

  def clean_nodeset(nodeset)
    # gathering nodes that are not present in @nodes and removing them
    tmpset = nodeset.diff(@nodes)
    tmpset.set.each do |node|
      nodeset.remove(node)
    end

    # gathering nodes that are present in @nodes_done and removing them
    @nodes_done.set.each do |node|
      nodeset.remove(node)
    end
  end

  def done?()
    @nodes.empty? or @nodes_done.equals?(@nodes)
  end

  def run_task(task)
    #debug("RUN_TASK/#{task.name} #{task.nodes.to_s_fold}")
    thr = Thread.new { task.run }

    timeout = (@config[task.name] ? @config[task.name][:timeout] : nil)
    success = true

    if timeout and timeout > 0
      timestart = Time.now
      sleep(TIMER_CKECK_PITCH) while ((Time.now - timestart) < timeout) and (thr.alive?)
      if thr.alive?
        thr.kill
        success = false
      end
    end

    debug("(#{task.nodes.id}) !!! Timeout in #{task.name} with #{task.nodes.to_s_fold}") unless success

    success = success && thr.value

    task.mutex.synchronize do
      #debug("RUN_JOIN #{task.name} #{task.nodes.to_s_fold}")
      clean_nodeset(task.nodes)

      #debug("RUN_SETS #{task.name} success:#{success} #{task.nodes.to_s_fold}:#{task.nodes.empty?} ok:#{task.nodes_ok.to_s_fold} ko:#{task.nodes_ko.to_s_fold}")
      if success
        treated = Nodes::NodeSet.new

        unless task.nodes_ok.empty?
          clean_nodeset(task.nodes_ok)
          #debug("RUN_PUSH OK #{task.name} #{task.nodes_ok.to_s_fold}")
          task.nodes_ok.linked_copy(treated)
          @queue.push({ :task => task, :status => 'OK', :nodes => task.nodes_ok})
        end

        unless task.nodes_ko.empty?
          clean_nodeset(task.nodes_ko)
          #debug("RUN_PUSH KO #{task.name} #{task.nodes_ko.to_s_fold}")
          task.nodes_ko.linked_copy(treated)
        end

        # Set nodes with no status as KO
        unless treated.equals?(task.nodes)
          tmp = task.nodes.diff(treated)
          #debug("RUN_TREATED diff:#{tmp.to_s_fold} nodes_ko:#{task.nodes_ko.to_s_fold}")
          tmp.move(task.nodes_ko)
        end

        @queue.push({ :task => task, :status => 'KO', :nodes => task.nodes_ko}) unless task.nodes_ko.empty?

      elsif !task.nodes.empty?
        #debug("RUN_PUSH ALL KO #{task.name} #{task.nodes.to_s_fold}")
        task.nodes_ko().clean()
        task.nodes().linked_copy(task.nodes_ko())
        @queue.push({ :task => task, :status => 'KO', :nodes => task.nodes_ko})
      end
      #debug("DONE_TASK #{task.name} #{task.nodes.to_s_fold}")
    end
  end

  def start()
    #debug("START")
    load_config()
    @nodes_done.clean()

    until (done?)
      #debug("WAIT_POP #{@nodes_done.set.size}/#{@nodes.set.size}")

      begin
        sleep(QUEUE_CKECK_PITCH)
        query = @queue.pop
      rescue ThreadError
        retry unless done?
      end

      #debug("NEW_TASK/#{(query[:task] ? query[:task].name : 'nil')}")

      @threads.each_value do |thread|
        thread.join unless thread.alive?
      end

      # Don't do anything if the nodes was already treated
      clean_nodeset(query[:nodes])

      next if !query[:nodes] or query[:nodes].empty?

      curtask = query[:task]
      newtask = {
        :idx => 0,
        :subidx => 0,
        :context => (curtask ? curtask.context.dup : { })
      }
      newtask[:context][:retries] = 0 unless newtask[:context][:retries]

      continue = true

      if query[:status] and curtask
        #debug("TREAT_STATUS #{query[:nodes].to_s_fold}")
        if query[:status] == 'OK'
          #debug("TREAT_OK #{query[:nodes].to_s_fold}")
          if (curtask.idx + 1) < tasks().length
            newtask[:idx] = curtask.idx + 1
            newtask[:context][:retries] = 0
          else
            #debug("SUCCESS #{query[:nodes].to_s_fold}")
            curtask.mutex.synchronize do
              success_task(curtask,query[:nodes])
              curtask.clean_nodes(query[:nodes])
            end
            continue = false
          end
        elsif query[:status] == 'KO'
          #debug("TREAT_KO #{query[:nodes].to_s_fold}")
          if curtask.context[:retries] < (@config[curtask.name][:retries] - 1)
            newtask[:idx] = curtask.idx
            newtask[:subidx] = curtask.subidx
            newtask[:context][:retries] += 1
          else
            tasks = tasks()
            if multi_task?(curtask.idx,tasks) \
            and curtask.subidx < (tasks[curtask.idx].size - 1)
              newtask[:idx] = curtask.idx
              newtask[:subidx] = curtask.subidx + 1
              newtask[:context][:retries] = 0
            else
              curtask.mutex.synchronize do
                fail_task(curtask,query[:nodes])
                curtask.clean_nodes(query[:nodes])
              end
              continue = false
            end
          end
        end
        curtask.mutex.synchronize { curtask.clean_nodes(query[:nodes]) } if continue
      end

      #debug("TREAT_CONT #{continue}")
      if continue
        #debug("TREAT_PARAMS #{newtask.inspect}")
        task = create_task(
          newtask[:idx],
          newtask[:subidx],
          query[:nodes],
          newtask[:context]
        )

        @threads[task] = Thread.new { run_task(task) }
      end

    end

    #debug("QUIT #{@nodes_done.set.size}/#{@nodes.set.size}")
  end

  def kill()
    @threads.each do |thread|
      thread.kill
      thread.join
    end
    @nodes_done.free()
  end
end

class TaskedTaskManager < TaskManager
  include Task

  attr_reader :name, :nodes, :idx, :subidx, :nodes_ok, :nodes_ko, :context, :mqueue, :mutex

  def initialize(name, idx, subidx, nodes, manager_queue, context = {}, params = [])
    super(nodes)
    @name = name.to_sym
    @idx = idx
    @subidx = subidx
    @mqueue = manager_queue
    @context = context
    @params = params
    @mutex = Mutex.new

    @nodes_ok = Nodes::NodeSet.new(@nodes.id)
    @nodes_ko = Nodes::NodeSet.new(@nodes.id)
  end

  def success_task(task,nodeset)
    super(task,nodeset)
    nodeset.linked_copy(@nodes_ok)

    split_nodeset(task.nodes,@nodes_ok) unless task.nodes.equals?(@nodes_ok)

    raise_nodes(@nodes_ok,'OK') if @config[task.name][:raisable]
  end

  def fail_task(task,nodeset)
    super(task,nodeset)
    nodeset.linked_copy(@nodes_ko)

    split_nodeset(task.nodes,@nodes_ko) unless task.nodes.equals?(@nodes_ko)

    raise_nodes(@nodes_ko,'KO') if @config[task.name][:raisable]
  end

  def clean_nodes(nodeset)
    super(nodeset)

    if nodeset == @nodes_done
      @nodes_done.clean()
    else
      nodeset.set.each do |node|
        @nodes_done.remove(node)
      end
    end
  end
end


# Now the implementation in Kadeploy

class Workflow < TaskManager
  attr_reader :nodes_ok, :nodes_ko

  def initialize(nodeset)
    super(nodeset)

    @nodes_ok = Nodes::NodeSet.new
    @nodes_ko = Nodes::NodeSet.new
  end

  def tasks()
    raise 'Should be reimplemented'
  end

  def success_task(task,nodeset)
    super(task,nodeset)
    nodeset.linked_copy(@nodes_ok)

    debug("### Add #{nodeset.to_s_fold} to OK nodeset")
  end

  def fail_task(task,nodeset)
    super(task,nodeset)
    nodeset.linked_copy(@nodes_ko)

    debug("### Add #{nodeset.to_s_fold} to KO nodeset")
  end

  def create_task(idx,subidx,nodes,context)
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
      @queue,
      context,
      nil
    )
  end
end

class Macrostep < TaskedTaskManager
  def run()
    debug("(#{@nodes.id}) === Launching #{self.class.name} on #{@nodes.to_s_fold}")

    start()
    return true
  end

  def create_task(idx,subidx,nodes,context)
    taskval = get_task(idx,subidx)

    Microstep.new(
      taskval[0],
      idx,
      subidx,
      nodes,
      @queue,
      context,
      taskval[1..-1]
    )
  end

  def success_task(task,nodeset)
    super(task,nodeset)
    debug("(#{@nodes.id}) <<< Raising #{nodeset.to_s_fold} from #{self.class.name}")
  end

  def fail_task(task,nodeset)
    super(task,nodeset)
    debug("(#{@nodes.id}) <<< Raising #{nodeset.to_s_fold} from #{self.class.name}")
  end

  ## to be defined in each macrostep class
  # def load_config()
  # end
  #
  # def tasks()
  # end
end

class Microstep < QueueTask
  def initialize(name, idx, subidx, nodes, manager_queue, context = {}, params = [])
    super(name, idx, subidx, nodes, manager_queue, context, params)
  end

  def run()
    debug("(#{@nodes.id})   --- Launching #{@name} on #{@nodes.to_s_fold}")

    #debug("\trun #{@name}/#{@params.inspect}")
    return send("ms_#{@name}".to_sym,*@params)
  end

  # ...
  # microstep methods
  # ...
end
