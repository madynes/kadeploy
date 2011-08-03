# Kadeploy 3.1
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008-2011
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

module ProcessManagement
  private
  # Get the childs of a process
  #
  # Arguments
  # * father: pid of the father
  # Output
  # * return an Array of the pid
  def ProcessManagement::get_childs(father)
    result = Array.new
    cmd = "ps -eo pid,ppid |grep #{father}"
    tab = `#{cmd}`.split("\n")
    tab.each { |line|
      line =~ /\A[\ ]*(\d+)[\ ]*(\d+)[\ ]*\Z/
      content = Regexp.last_match
      pid = content[1].to_i
      ppid = content[2].to_i
      if (ppid == father) then
        result.push(pid)
      end
    }
    return result
  end

  # Kill a process subtree
  #
  # Arguments
  # * father: pid of the father
  # Output
  # * nothing
  def ProcessManagement::kill_tree(father)
    finished = false
    while not finished
      list = ProcessManagement::get_childs(father)
      if not list.empty? then
        list.each { |pid|
          ProcessManagement::kill_tree(pid)
          begin
            Process.kill(9, pid)
            Process.waitpid(pid, Process::WUNTRACED)
          rescue
          end
        }
      else
        finished = true
      end
    end
  end

  public

  # Kill a process and all its childs
  #
  # Arguments
  # * father: pid of the process
  # Output
  # * nothing
  def ProcessManagement::killall(pid)
    ProcessManagement::kill_tree(pid)
    begin
      Process.kill(9, pid)
      Process.waitpid(pid, Process::WUNTRACED)
    rescue
    end
  end

  class Container
    @instances = nil
    
    # Constructor of Container
    #
    # Arguments
    # * output: nothing
    # Output
    # * nothing
    def initialize
      @instances = Hash.new
    end

    # Add a process in a container
    #
    # Arguments
    # * tid: thread id of the instance that launched the process
    # * pid: process id
    # Output
    # * nothing
    def add_process(tid, pid)
      if not @instances.has_key?(tid) then
        @instances[tid] = Array.new
      end
      @instances[tid].push(pid)
    end

    # Remove a process of a container
    #
    # Arguments
    # * tid: thread id of the instance that launched the process
    # * pid: process id
    # Output
    # * nothing
    def remove_process(tid, pid)
      if @instances.has_key?(tid) then
        @instances[tid].delete(pid)
      end
    end

    # Kill all the processes launched in the container of the given instance
    #
    # Arguments
    # * tid: thread id of the instance that launched the process
    # Output
    # * nothing
    def killall(tid)
      if @instances.has_key?(tid) then
        @instances[tid].each { |pid|
          ProcessManagement::killall(pid)
          remove_process(tid, pid)
        }
        @instances[tid] = nil
        @instances.delete(tid)
      end
    end
  end
end
