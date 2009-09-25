# Kadeploy 3.0
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008, 2009
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
    rescue
    end
  end

  class Container
    @instances = nil
    
    def initialize
      @instances = Hash.new
    end

    def add_process(tid, pid)
      if not @instances.has_key?(tid) then
        @instances[tid] = Array.new
      end
      @instances[tid].push(pid)
    end

    def remove_process(tid, pid)
      if @instances.has_key?(tid) then
        @instances[tid].delete(pid)
      end
    end

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
