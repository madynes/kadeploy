require 'thread'
require 'timeout'

require 'nodes'

#Thread::abort_on_exception = true

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

    def nsid()
      raise 'Should be reimplemented'
    end

    def mqueue()
      raise 'Should be reimplemented'
    end

    def cleaner()
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

    def status()
      raise 'Should be reimplemented'
    end

    def raise_nodes(nodeset,status,nodesetid=nil)
      # Nodes of this nodeset are not threated by this task anymore
      nodeset.set.each do |node|
        nodes().remove(node)
      end
      # Clean the nodeset
      tmpnodeset = Nodes::NodeSet.new(nodeset.id)
      nodeset.move(tmpnodeset)
      mqueue().push({
        :task => self,
        :status => status,
        :nodes => tmpnodeset,
        :nsid => (nodesetid ? nodesetid : nsid())
      })
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

    attr_reader :name, :nodes, :nsid, :idx, :subidx, :nodes_brk, :nodes_ok, :nodes_ko, :context, :mqueue, :mutex

    def initialize(name, idx, subidx, nodes, nsid, manager_queue, context = {}, params = [])
      @name = name.to_sym
      @nodes = nodes
      @nsid = nsid
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

    def cleaner
      nil
    end
  end

  class TaskManager
    attr_reader :nodes, :nodes_done, :static_context, :cleaner

    TIMER_CKECK_PITCH = 0.5
    #QUEUE_CKECK_PITCH = 0.3
    CLEAN_THREADS_PITCH = 5

    def initialize(nodeset,static_context = {})
      raise if nodeset.nil?
      @config = {} unless @config
      @static_context = static_context
      @queue = Queue.new
      @threads = {}
      @nodes = nodeset #all nodes
      @nodes_done = Nodes::NodeSet.new(@nodes.id)
      @runthread = nil
      @cleaner = nil

      load_tasks()
      load_config()
      init_queue()
    end

    def create_task(idx,subidx,nodes,nsid,context)
      raise 'Should be reimplemented'
    end

    def tasks()
      raise 'Should be reimplemented'
    end

    def nsid()
      raise 'Should be reimplemented'
    end

    def custom(task,operation)
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

    def split!(nsid0,nsid1,ns1,nsid2,ns2)
    end

    def kill!()
    end

    def start!()
    end

    def done!()
    end

    def init_queue()
      nodeset = Nodes::NodeSet.new(@nodes.id)
      @nodes.linked_copy(nodeset)
      @queue.push({ :nodes => nodeset, :nsid => nsid() })
    end

    def init_context(task=nil)
      if task
        ret = task.context
        ret[:local] = task.context[:local].dup
      else
        ret = { :local => {} }
      end
      ret[:local][:parent] = self
      ret[:local][:retries] = 0 unless ret[:local][:retries]
      @static_context.merge(ret)
    end

    def init_config()
      tasks = tasks()

      proc_init = Proc.new do |taskname|
        @config[taskname.to_sym] = {} unless @config[taskname.to_sym]
        @config[taskname.to_sym] = conf_task_default().merge(@config[taskname.to_sym])
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
        :breakpoint => false,
        :config => nil,
        :custom_pre => nil,
        :custom_post => nil,
        :custom_sub => nil,
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

    def status()
      ret = {}
      @threads.each_key{ |task| ret[task.name] = task.status }
      ret[:OK] = @nodes_ok unless @nodes_ok.empty?
      ret[:KO] = @nodes_ko unless @nodes_ko.empty?
      ret
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

    def success_task(task,nodeset,rnsid=nil)
      done_task(task,nodeset)
      nodeset.linked_copy(nodes_ok())
      success!(task,nodeset)
    end

    def fail_task(task,nodeset,rnsid=nil)
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

    def split_nodeset(task)
      ok_nsid = Nodes::NodeSet.newid(context)
      ko_nsid = Nodes::NodeSet.newid(context)

      split!(task.nsid,ok_nsid,task.nodes_ok,ko_nsid,task.nodes_ko)
      [ok_nsid,ko_nsid]
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
      @cleaner.join
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
        while ((Time.now - timestart) < timeout) and (thr.alive?)
          task.cleaner.join if task.cleaner and !task.cleaner.alive?
          sleep(TIMER_CKECK_PITCH)
        end
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

        ok_nsid = task.nsid
        ko_nsid = task.nsid
        if success
          treated = Nodes::NodeSet.new

          if !task.nodes_ok.empty? and !task.nodes_ko.empty?
            ok_nsid,ko_nsid = split_nodeset(task)
          end

          unless task.nodes_ko.empty?
            clean_nodeset(task.nodes_ko)
            task.nodes_ko.linked_copy(treated)
          end

          unless task.nodes_ok.empty?
            # by default if nodes are present in nodes_ok and nodes_ko,
            # consider them as KO
            clean_nodeset(task.nodes_ok,treated)
            task.nodes_ok.linked_copy(treated)
            @queue.push({
              :task => task,
              :status => :OK,
              :nodes => task.nodes_ok,
              :nsid => ok_nsid
            })
          end

          # Set nodes with no status as KO
          unless treated.equal?(task.nodes)
            tmp = task.nodes.diff(treated)
            tmp.move(task.nodes_ko)
          end

          @queue.push({
            :task => task,
            :status => :KO,
            :nodes => task.nodes_ko,
            :nsid => ko_nsid
          }) unless task.nodes_ko.empty?

        elsif !task.nodes.empty?
          task.nodes_ko().clean()
          task.nodes().linked_copy(task.nodes_ko())
          @queue.push({
            :task => task,
            :status => :KO,
            :nodes => task.nodes_ko,
            :nsid => task.nsid
          })
        end
      end
    end

    def start()
      @nodes_done.clean()
      @runthread = Thread.current
      # A thread is launched to clean and join threads that was unexpectedly closed
      # That helps to raise exceptions from one imbricated element of the automata to the main thread
      @cleaner = Thread.new do
        while !done? and @runthread.alive?
          sleep(CLEAN_THREADS_PITCH)
          clean_threads()
        end
        @runthread.join unless @runthread.alive?
      end
      start!
      curtask = nil

      until (done?)
        begin
          #sleep(QUEUE_CKECK_PITCH)
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
        query[:nsid] = curtask.nsid if query[:nsid].nil? and curtask

        continue = true

        if query[:status] and curtask
          if query[:status] == :BRK
            break_task(curtask,query[:nodes])
            #break!(curtask,query[:nodes])
            continue = false
          elsif query[:status] == :OK
            if (curtask.idx + 1) < tasks().length
              newtask[:idx] = curtask.idx + 1
              newtask[:context][:local][:retries] = 0
            else
              curtask.mutex.synchronize do
                success_task(curtask,query[:nodes],query[:nsid])
                #success!(curtask,query[:nodes])
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
                  fail_task(curtask,query[:nodes],query[:nsid])
                  #fail!(curtask,query[:nodes])
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
            query[:nsid],
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
      if @cleaner.alive?
        @cleaner.kill
        @cleaner.join
      end
      @cleaner = nil

      done!
      curtask
    end

    def kill()
      clean_threads()
      @queue.clear()

      unless @runthread.nil?
        @runthread.kill if @runthread.alive?
        @runthread.join
        @runthread = nil
      end

      unless @cleaner.nil?
        @cleaner.kill if @cleaner.alive?
        @cleaner.join
        @cleaner = nil
      end

      @threads.each_pair do |task,threads|
        task.kill
        threads.each_pair do |key,thread|
          thread.kill
          thread.join
        end
      end

      @threads = {}
      @nodes_done.clean()
      @queue.clear()
      @nodes.linked_copy(@nodes_done)

      kill!
    end
  end

  class TaskedTaskManager < TaskManager
    alias_method :__kill__, :kill
    alias_method :__status__, :status
    include Task

    attr_reader :name, :nodes, :nsid, :idx, :subidx, :nodes_brk, :nodes_ok, :nodes_ko, :mqueue, :mutex, :cleaner

    def initialize(name, idx, subidx, nodes, nsid, manager_queue, context = {}, config={}, params = [])
      @nsid = nsid
      if config and !config.empty?
        @config = {}
        init_config()
        config(config)
        load_config()
      end
      super(nodes,context)
      @name = name.to_sym
      @idx = idx
      @subidx = subidx
      @mqueue = manager_queue
      @params = params
      @mutex = Mutex.new

      @nodes_brk = Nodes::NodeSet.new(@nodes.id)
      @nodes_ok = Nodes::NodeSet.new(@nodes.id)
      @nodes_ko = Nodes::NodeSet.new(@nodes.id)
    end

    def context
      @static_context
    end

    def break_task(task,nodeset)
      super(task,nodeset)
      raise_nodes(@nodes_brk,:BRK)
    end

    def split_nodeset(task)
      ok_nsid,ko_nsid = super(task)
      @nsid = ok_nsid
      [ok_nsid,ko_nsid]
    end

    def success_task(task,nodeset,rnsid=nil)
      @nsid = task.nsid
      super(task,nodeset)

      if @config[task.name][:raisable]
        new_nsid = nil
        if rnsid != task.nsid
          new_nsid = rnsid
        elsif !task.nodes.equal?(task.nodes_ok)
          nsid1,new_nsid = split_nodeset(task)
        else
          new_nsid = task.nsid
        end
        #task.nsid = new_nsid
        raise_nodes(@nodes_ok,:OK,new_nsid)
      end
    end

    def fail_task(task,nodeset,rnsid=nil)
      @nsid = task.nsid
      super(task,nodeset)

      if @config[task.name][:raisable]
        new_nsid = nil
        if rnsid != task.nsid
          new_nsid = rnsid
        elsif !task.nodes.equal?(task.nodes_ko)
          nsid1,new_nsid = split_nodeset(task)
        else
          new_nsid = task.nsid
        end
        #task.nsid = new_nsid
        raise_nodes(@nodes_ko,:KO,new_nsid)
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
      last_task = start()
      @nsid = last_task.nsid
      return true
    end

    def kill()
      __kill__()
      @nodes_ok.clean()
      @nodes.linked_copy(@nodes_ko)
    end

    def status()
      __status__()
    end
  end
end
