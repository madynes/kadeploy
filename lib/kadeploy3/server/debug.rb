require 'thread'

module Kadeploy

module Debug
  def self.prefix(clid,nsid=nil)
    ns = nsid if !nsid.nil? and nsid > 0

    if !clid.nil? and !clid.empty?
      "[#{clid}#{(ns.nil? ? '' : ".#{ns}")}] "
    elsif !ns.nil?
      "[#{ns}] "
    else
      ''
    end
  end

  def self.format(msg)
    "#{'%.5f' % Time.now.to_f}|#{msg}"
  end

  class FileOutput
    attr_accessor :prefix
    def initialize(file,verbose_level=0,prefix='')
      @file = file
      @verbose_level = verbose_level
      @prefix = prefix
      @lock = Mutex.new
    end

    def free()
      @file = nil
      @verbose_level = nil
      @prefix = nil
      @lock = nil
    end

    def write(msg,lvl=-1)
      if lvl <= @verbose_level
        @lock.synchronize do
          f = File.new(@file, File::CREAT | File::APPEND | File::WRONLY, 0644)
          f.flock(File::LOCK_EX)
          if msg.is_a?(Array)
            msg.each{|m| f.write("#{prefix}#{m}\n") }
          elsif msg.is_a?(String)
            f.write("#{prefix}#{msg}\n")
          else
            raise
          end
          f.flock(File::LOCK_UN)
          f.close
        end
      end
    end
  end

  class OutputControl
    # Constructor of OutputControl
    #
    # Arguments
    # * verbose_level: verbose level at the runtime
    # * debug: boolean user to know if the extra debug must be used or not
    # Output
    # * nothing
    def initialize(verbose_level, file = nil, cluster_id=nil)
      @verbose_level = verbose_level
      @output = ''
      @file = file
      @cluster_id = cluster_id
      @lock = Mutex.new
    end

    def free()
      @verbose_level = nil
      @output = nil
      @file = nil
      @cluster_id = nil
      @lock = nil
    end

    # Print a message according to a specified debug level
    #
    # Arguments
    # * lvl: debug level of the message
    # * msg: message
    # * nodeset: print with this NodeSet id
    # Output
    # * prints the message on the server and on the client
    def push(lvl, msg, nsid=nil, print_prefix = true)
      @lock.synchronize do
        msg = "#{Debug.prefix(@cluster_id,nsid)}#{msg}" if print_prefix
        @output << Debug.format("#{msg}\n") if lvl <= @verbose_level
        @file.write(msg,lvl) if @file
      end
    end

    def pop()
      @lock.synchronize do
        ret = @output
        @output = ''
        ret
      end
    end

    def empty?()
      @lock.synchronize do
        @output.empty?
      end
    end

    def write(msg)
      @lock.synchronize do
        @output << msg
      end
    end
  end

  class DebugControl
    def initialize()
      @debug = {}
      @lock = Mutex.new
    end

    def free()
      @debug = nil
      @lock = nil
    end

    def push(cmd, nodeset, stdout=nil, stderr=nil, status=nil)
      return unless nodeset

      out = nil
      err = nil
      stat = nil

      if stdout or stderr or status
        out = stdout || ''
        err = stderr || ''
        stat = status || ''
      end

      @lock.synchronize do
        nodeset.set.each do |node|
          if !stdout and !stderr and !status
            out = node.last_cmd_stdout || ''
            err = node.last_cmd_stderr || ''
            stat = node.last_cmd_exit_status || ''
          end
          @debug[node.hostname] = '' unless @debug[node.hostname]
          @debug[node.hostname] << Debug.format("-------------------------\n")
          @debug[node.hostname] << Debug.format("NODE: #{node.hostname}\n")
          @debug[node.hostname] << Debug.format("-------------------------\n")
          @debug[node.hostname] << Debug.format("COMMAND: #{cmd}\n")
          out.each_line do |line|
            @debug[node.hostname] << Debug.format("STDOUT: #{line}\n")
          end
          err.each_line do |line|
            @debug[node.hostname] << Debug.format("STDERR: #{line}\n")
          end
          stat.to_s.each_line do |line|
            @debug[node.hostname] << Debug.format("STATUS: #{line}\n")
          end
        end
      end
    end

    def pop(node=nil)
      @lock.synchronize do
        if node
          ret = @debug[node]
          @debug[node] = nil
          ret
        else
          ret = ''
          @debug.each_key do |n|
            ret << @debug[n] if @debug[n]
            @debug[n] = nil
          end
          (ret.empty? ? nil : ret)
        end
      end
    end

    def empty?()
      ret = true
      @lock.synchronize do
        @debug.each_pair do |node,v|
          if v and !v.empty?
            ret = false
            break
          end
        end
      end
      ret
    end
  end

  class Logger
    # Constructor of Logger
    #
    # Arguments
    # * node_set: NodeSet that contains the nodes implied in the deployment
    # * config: instance of Config
    # * db: database handler
    # * user: username
    # * wid: deployment id
    # * start: start time
    # * env: environment name
    # * anonymous_env: anonymous environment or not
    # Output
    # * nothing
    def initialize(nodes, user, wid, start, env, anonymous_env, file=nil, db=nil)
      @nodes = {}
      nodes.each do |node|
        @nodes[node] = create_node_infos(user, wid, start, env, anonymous_env)
      end
      @file = file
      @database = db
    end

    def free()
      @nodes = nil
      @file = nil
      @database = nil
    end

    # Create an hashtable that contains all the information to log
    #
    # Arguments
    # * user: username
    # * wid: deployment id
    # * start: start time
    # * env: environment name
    # * anonymous_env: anonymous environment or not
    # Output
    # * returns an Hash instance
    def create_node_infos(user, wid, start, env, anonymous_env)
      {
        "wid" => wid,
        "user" => user,
        "step1" => String.new,
        "step2" => String.new,
        "step3" => String.new,
        "timeout_step1" => 0,
        "timeout_step2" => 0,
        "timeout_step3" => 0,
        "retry_step1" => 0,
        "retry_step2" => 0,
        "retry_step3" => 0,
        "start" => start,
        "step1_duration" => 0,
        "step2_duration" => 0,
        "step3_duration" => 0,
        "env" => env||'',
        "anonymous_env" => anonymous_env,
        "md5" => String.new,
        "success" => false,
        "error" => String.new,
      }
    end

    # Set a value for some nodes in the Logger
    #
    # Arguments
    # * op: information to set
    # * val: value for the information
    # * node_set(opt): Array of nodes
    # Output
    # * nothing
    def set(op, val, node_set = nil)
      if (node_set != nil)
        node_set.make_array_of_hostname.each { |n|
          @nodes[n][op] = val
        }
      else
        @nodes.each_key { |k|
          @nodes[k][op] = val
        }
      end
    end

    # Set the error value for a set of nodes
    #
    # Arguments
    # * node_set: Array of nodes
    # Output
    # * nothing
    def error(nodeset,states)
      nodeset.set.each do |node|
        state = states.get(node.hostname)
        node.last_cmd_stderr = "#{state[:macro]}-#{state[:micro]}: #{node.last_cmd_stderr}"
        states.set(node.hostname,nil,nil,'ko',node.last_cmd_stderr)
        @nodes[node.hostname]["error"] = node.last_cmd_stderr
      end
    end

    # Increment an information for a set of nodes
    #
    # Arguments
    # * op: information to increment
    # * node_set(opt): Array of nodes
    # Output
    # * nothing
    def increment(op, node_set = nil)
      if (node_set != nil)
        node_set.make_array_of_hostname.each { |n|
          @nodes[n][op] += 1
        }
      else
        @nodes.each_key { |k|
          @nodes[k][op] += 1
        }
      end
    end

    # Generic method to dump the logged information
    #
    # Arguments
    # * nothing
    # Output
    # * nothing
    def dump
      dump_to_file if @file
      dump_to_db if @database
    end

    # Dump the logged information to the database
    #
    # Arguments
    # * nothing
    # Output
    # * nothing
    def dump_to_db
      @nodes.each_pair { |hostname, node_infos|
        @database.run_query(
         "INSERT INTO log ( \
          wid, \
          user, \
          hostname, \
          step1, \
          step2, \
          step3, \
          timeout_step1, \
          timeout_step2, \
          timeout_step3, \
          retry_step1, \
          retry_step2, \
          retry_step3, \
          start, \
          step1_duration, \
          step2_duration, \
          step3_duration, \
          env, \
          anonymous_env, \
          md5, \
          success, \
          error) \
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
          node_infos["wid"],
          node_infos["user"],
          hostname,
          node_infos["step1"],
          node_infos["step2"],
          node_infos["step3"],
          node_infos["timeout_step1"],
          node_infos["timeout_step2"],
          node_infos["timeout_step3"],
          node_infos["retry_step1"],
          node_infos["retry_step2"],
          node_infos["retry_step3"],
          node_infos["start"].to_i,
          node_infos["step1_duration"],
          node_infos["step2_duration"],
          node_infos["step3_duration"],
          node_infos["env"],
          node_infos["anonymous_env"].to_s,
          node_infos["md5"],
          node_infos["success"].to_s,
          node_infos["error"].gsub(/"/, "\\\"")
        )
      }
    end

    # Dump the logged information to a file
    #
    # Arguments
    # * nothing
    # Output
    # * nothing
    def dump_to_file
      out = []
      @nodes.each_pair do |hostname, node_infos|
        str = node_infos["wid"].to_s + "," + hostname + "," + node_infos["user"] + ","
        str += node_infos["step1"] + "," + node_infos["step2"] + "," + node_infos["step3"]  + ","
        str += node_infos["timeout_step1"].to_s + "," + node_infos["timeout_step2"].to_s + "," + node_infos["timeout_step3"].to_s + ","
        str += node_infos["retry_step1"].to_s + "," + node_infos["retry_step2"].to_s + "," +  node_infos["retry_step3"].to_s + ","
        str += node_infos["start"].to_i.to_s + ","
        str += node_infos["step1_duration"].to_s + "," + node_infos["step2_duration"].to_s + "," + node_infos["step3_duration"].to_s + ","
        str += node_infos["env"] + "," + node_infos["anonymous_env"].to_s + "," + node_infos["md5"] + ","
        str += node_infos["success"].to_s + "," + node_infos["error"].to_s
        out << str
      end
      @file.write(out)
    end
  end
end


module Printer
  def debug(level,msg,nodesetid=nil,opts={})
    return unless output()
    output().push(level,msg,nodesetid)
  end

  def log(operation,value=nil,nodeset=nil,opts={})
    return unless logger()
    if opts[:increment]
      logger().increment(operation, nodeset)
    else
      logger().set(operation,value,nodeset)
    end
  end
end

end
