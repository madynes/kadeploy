require 'thread'
require 'timeout'

require 'nodes'

Thread::abort_on_exception = true

module Automata

  module Task
    def run
      raise 'Should be reimplemented'
    end

    # ! do not use it in your run()
    def nodes()
      raise 'Should be reimplemented'
    end

    def nodes_brk()
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

    def kill()
      raise 'Should be reimplemented'
    end

    def raise_nodes(nodeset,status)
      # Nodes of this nodeset are not threated by this task anymore
      nodeset.set.each do |node|
        nodes().remove(node)
      end
      # Clean the nodeset
      tmpnodeset = Nodes::NodeSet.new(nodeset.id)
      nodeset.move(tmpnodeset)

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

    attr_reader :name, :nodes, :idx, :subidx, :nodes_brk, :nodes_ok, :nodes_ko, :context, :mqueue, :mutex

    def initialize(name, idx, subidx, nodes, manager_queue, context = {}, params = [])
      @name = name.to_sym
      @nodes = nodes
      @idx = idx
      @subidx = subidx
      @mqueue = manager_queue
      @context = context
      @params = params
      @mutex = Mutex.new

      @nodes_brk = Nodes::NodeSet.new(@nodes.id)
      @nodes_ok = Nodes::NodeSet.new(@nodes.id)
      @nodes_ko = Nodes::NodeSet.new(@nodes.id)
    end
  end

  class TaskManager
    attr_reader :nodes, :nodes_done, :static_context

    TIMER_CKECK_PITCH = 0.5
    QUEUE_CKECK_PITCH = 0.1

    def initialize(nodeset,static_context = {})
      raise if nodeset.nil?
      @config = {}
      @static_context = static_context
      @queue = Queue.new
      @threads = {}
      @nodes = nodeset #all nodes
      @nodes_done = Nodes::NodeSet.new(@nodes.id)
      @runthread = nil

      load_tasks()
      load_config()
      init_queue()
    end

    def create_task(idx,subidx,nodes,context)
      raise 'Should be reimplemented'
    end

    def tasks()
      raise 'Should be reimplemented'
    end

    def break!(task,nodeset)
    end

    def success!(task,nodeset)
    end

    def fail!(task,nodeset)
    end

    def timeout!(task)
    end

    def retry!(task)
    end

    def split!(ns,ns1,ns2)
    end

    def kill!()
    end

    def start!()
    end

    def done!()
    end

    def init_queue()
      nodeset = Nodes::NodeSet.new
      @nodes.linked_copy(nodeset)
      @queue.push({ :nodes => nodeset })
    end

    def init_context(task=nil)
      ret = (task ? task.context : { :local => {} })
      ret[:local][:parent] = self
      ret[:local][:retries] = 0 unless ret[:local][:retries]
      @static_context.merge(ret)
    end

    def init_config()
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

    # To be redefined
    def load_config()
      init_config()
    end

    # To be used at runtine
    def config(config)
      unless config.nil?
        config.each_pair do |taskname,taskconf|
          conf_task(taskname,taskconf)
        end
      end
      self
    end

    def conf_task_default()
      {
        :timeout => 0,
        :retries => 0,
        :raisable => true,
        :config => nil,
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

    def load_tasks
    end

    def done_task(task,nodeset)
      @nodes_done.add(nodeset)
    end

    def break_task(task,nodeset)
      done_task(task,nodeset)
      nodeset.linked_copy(nodes_brk())
      break!(task,nodeset)
    end

    def success_task(task,nodeset)
      done_task(task,nodeset)
      nodeset.linked_copy(nodes_ok())
      success!(task,nodeset)
    end

    def fail_task(task,nodeset)
      done_task(task,nodeset)
      nodeset.linked_copy(nodes_ko())
      fail!(task,nodeset)
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
      unless tmpns.empty?
        tmpns.id = Nodes::NodeSet.newid(context)
        newns.id = Nodes::NodeSet.newid(context)

        ## Get the right nodeset
        #allns = Nodes::NodeSet.new(startns.id)
        #tmpns.linked_copy(allns)
        #newns.linked_copy(allns)

        split!(startns,tmpns,newns)

        startns.id = tmpns.id
      end
    end

    def clean_nodeset(nodeset,exclude=nil)
      # gathering nodes that are not present in @nodes and removing them
      tmpset = nodeset.diff(@nodes)
      tmpset.set.each do |node|
        nodeset.remove(node)
      end

      # gathering nodes that are present in @nodes_done and removing them
      @nodes_done.set.each do |node|
        nodeset.remove(node)
      end

      # removing nodes from exclude nodeset
      if exclude
        exclude.set.each do |node|
          nodeset.remove(node)
        end
      end
    end

    def done?()
      @nodes.empty? or @nodes_done.equal?(@nodes)
    end

    def clean_threads
      @threads.each_pair do |task,threads|
        threads.each_pair do |key,thread|
          unless thread.alive?
            thread.join
            threads.delete(key)
          end
        end
        @threads.delete(task) if @threads[task].empty?
      end
    end

    def join_threads
      @threads.each_pair do |task,threads|
        threads.each_pair do |key,thread|
          thread.join
          threads.delete(key)
        end
        @threads.delete(task) if @threads[task].empty?
      end
    end

    def run_task(task)
      if @config[task.name] and @config[task.name][:breakpoint]
        clean_nodeset(task.nodes)
        @queue.push({ :task => task, :status => :BRK, :nodes => task.nodes})
        return
      end

      timeout = (@config[task.name] ? @config[task.name][:timeout] : nil)
      task.context[:local][:timeout] = timeout

      timestart = Time.now
      thr = Thread.new { task.run }
      @threads[task] = {} unless @threads[task]
      @threads[task][:run] = thr

      success = true

      if timeout and timeout > 0
        sleep(TIMER_CKECK_PITCH) while ((Time.now - timestart) < timeout) and (thr.alive?)
        if thr.alive?
          thr.kill
          task.kill
          success = false
          timeout!(task)
        end
      end
      thr.join

      task.context[:local][:duration] = Time.now - timestart

      success = success && thr.value
      @threads[task].delete(:run)
      @threads.delete(task) if @threads[task].empty?

      task.mutex.synchronize do
        clean_nodeset(task.nodes)

        if success
          treated = Nodes::NodeSet.new

          unless task.nodes_ko.empty?
            clean_nodeset(task.nodes_ko)
            task.nodes_ko.linked_copy(treated)
          end

          unless task.nodes_ok.empty?
            # by default if nodes are present in nodes_ok and nodes_ko,
            # consider them as KO
            clean_nodeset(task.nodes_ok,treated)
            task.nodes_ok.linked_copy(treated)
            @queue.push({ :task => task, :status => :OK, :nodes => task.nodes_ok})
          end

          # Set nodes with no status as KO
          unless treated.equal?(task.nodes)
            tmp = task.nodes.diff(treated)
            tmp.move(task.nodes_ko)
          end

          @queue.push({ :task => task, :status => :KO, :nodes => task.nodes_ko}) unless task.nodes_ko.empty?

        elsif !task.nodes.empty?
          task.nodes_ko().clean()
          task.nodes().linked_copy(task.nodes_ko())
          @queue.push({ :task => task, :status => :KO, :nodes => task.nodes_ko})
        end
      end
    end

    def start()
      @nodes_done.clean()
      @runthread = Thread.current
      start!

      until (done?)
        begin
          sleep(QUEUE_CKECK_PITCH)
          query = @queue.pop
        rescue ThreadError
          retry unless done?
        end

        clean_threads()

        # Don't do anything if the nodes was already treated
        clean_nodeset(query[:nodes])

        next if !query[:nodes] or query[:nodes].empty?

        curtask = query[:task]
        newtask = {
          :idx => 0,
          :subidx => 0,
          :context => init_context(curtask)
        }

        continue = true

        if query[:status] and curtask
          if query[:status] == :BRK
            break_task(curtask,query[:nodes])
            continue = false
          elsif query[:status] == :OK
            if (curtask.idx + 1) < tasks().length
              newtask[:idx] = curtask.idx + 1
              newtask[:context][:local][:retries] = 0
            else
              curtask.mutex.synchronize do
                success_task(curtask,query[:nodes])
                curtask.clean_nodes(query[:nodes])
              end
              continue = false
            end
          elsif query[:status] == :KO
            if curtask.context[:local][:retries] < (@config[curtask.name][:retries])
              newtask[:idx] = curtask.idx
              newtask[:subidx] = curtask.subidx
              newtask[:context][:local][:retries] += 1
              retry!(curtask)
            else
              tasks = tasks()
              if multi_task?(curtask.idx,tasks) \
              and curtask.subidx < (tasks[curtask.idx].size - 1)
                newtask[:idx] = curtask.idx
                newtask[:subidx] = curtask.subidx + 1
                newtask[:context][:local][:retries] = 0
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

        if continue
          task = create_task(
            newtask[:idx],
            newtask[:subidx],
            query[:nodes],
            newtask[:context]
          )

          @threads[task] = {
            :treatment => Thread.new { run_task(task) }
          }
        end
      end

      clean_threads()
      join_threads()
      @runthread = nil

      done!
    end

    def kill()
      clean_threads()

      unless @runthread.nil?
        @runthread.kill if @runthread.alive?
        @runthread.join
        @runthread = nil
      end

      @threads.each_pair do |task,threads|
        threads.each_pair do |key,thread|
          thread.kill
          thread.join
        end
        task.kill
      end

      @threads = {}
      @nodes_done.clean()
      @nodes.linked_copy(@nodes_done)

      kill!
    end
  end

  class TaskedTaskManager < TaskManager
    alias_method :__kill__, :kill
    include Task

    attr_reader :name, :nodes, :idx, :subidx, :nodes_brk, :nodes_ok, :nodes_ko, :context, :mqueue, :mutex

    def initialize(name, idx, subidx, nodes, manager_queue, context = {}, params = [])
      super(nodes,context)
      @name = name.to_sym
      @idx = idx
      @subidx = subidx
      @mqueue = manager_queue
      @context = context
      @params = params
      @mutex = Mutex.new

      @nodes_brk = Nodes::NodeSet.new(@nodes.id)
      @nodes_ok = Nodes::NodeSet.new(@nodes.id)
      @nodes_ko = Nodes::NodeSet.new(@nodes.id)
    end

    def break_task(task,nodeset)
      super(task,nodeset)
      raise_nodes(@nodes_brk,:BRK)
    end

    def success_task(task,nodeset)
      super(task,nodeset)

      if @config[task.name][:raisable]
        split_nodeset(task.nodes,@nodes_ok) unless task.nodes.equal?(@nodes_ok)
        task.nodes_ok.id,task.nodes_ko.id = task.nodes.id
        raise_nodes(@nodes_ok,:OK)
      end
    end

    def fail_task(task,nodeset)
      super(task,nodeset)

      if @config[task.name][:raisable]
        split_nodeset(task.nodes,@nodes_ko) unless task.nodes.equal?(@nodes_ko)
        task.nodes_ok.id,task.nodes_ko.id = task.nodes.id
        raise_nodes(@nodes_ko,:KO)
      end
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

    def run()
      start()
      return true
    end

    def kill()
      __kill__()
      @nodes_ok.clean()
      @nodes.linked_copy(@nodes_ko)
    end
  end
end
