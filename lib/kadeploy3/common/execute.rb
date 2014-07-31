module Kadeploy

# To be used as you're using Open3.popen3 in ruby 1.9.2
class Execute
  require 'thread'
  require 'fcntl'
  attr_reader :command, :exec_pid, :stdout, :stderr, :status
  @@forkmutex = Mutex.new

  def initialize(*cmd)
    @command = *cmd

    @exec_pid = nil

    @stdout = nil
    @stderr = nil
    @status = nil

    @child_io = nil
    @parent_io = nil

    @kill_lock = Mutex.new
  end

  def free
    @command = nil
    @stdout = nil
    @stderr = nil
  end

  def self.[](*cmd)
    self.new(*cmd)
  end

  def self.init_ios(opts={:stdin => false})
    if opts[:stdin]
      in_r, in_w = IO::pipe
      in_w.sync = true
    else
      in_r, in_w = [nil,nil]
    end

    out_r, out_w = opts[:stdout] == false ? [nil,nil] : IO::pipe
    err_r, err_w = opts[:stderr] == false ? [nil,nil] : IO::pipe

    [ [in_r,out_w,err_w], [in_w,out_r,err_r] ]
  end

  def run(opts={:stdin => false})
    @@forkmutex.synchronize do
      @child_io, @parent_io = Execute.init_ios(opts)
      @exec_pid = fork {
        begin

          #stdin
          STDIN.reopen(@child_io[0] || '/dev/null')

          #stdout
          STDOUT.reopen(@child_io[1] || '/dev/null')

          #stderr
          STDERR.reopen(@child_io[2] || '/dev/null')


          # Close useless file descriptors.
          # Since ruby 2.0, FD_CLOEXEC is set when ruby opens a descriptor.
          # After performing exec(), all file descriptors are closed excepted 0,1,2
          # https://bugs.ruby-lang.org/issues/5041
          if RUBY_VERSION < "2.0"
            ObjectSpace.each_object(IO) do |f|
              #Some IO objects are not initialized while testing.
              #So the function 'closed?' raises an exception. We ignore that.
              f.close  if !f.closed? && ![0,1,2].include?(f.fileno) rescue IOError
            end
          end
          exec(*@command)
        rescue SystemCallError, Exception => e
          STDERR.puts "Fork Error: #{e.message} (#{e.class.name})"
          STDERR.puts e.backtrace
        end
        exit! 1
      }

      @child_io.each do |io|
        io.close if io and !io.closed?
      end
    end
    result = [@exec_pid, *@parent_io]
    if block_given?
      begin
        ret = yield(*result)
        wait(opts)
        return ret
      ensure
        @parent_io.each do |io|
          begin
            io.close if io and !io.closed?
          rescue IOError
          end
        end if @parent_io
        @parent_io = nil
        @child_io = nil
      end
    end
    result
  end

  def run!(opts={:stdin => false})
    if block_given?
      run(opts,Proc.new)
    else
      run(opts)
    end
    self
  end

  # When :stdout_size or :stderr_size is given, if after have read the specified
  # amount of data, the pipe is not empty, the 4th return value is set to false
  def wait(opts={:checkstatus => true})
    unless @exec_pid.nil?
      emptypipes = true
      begin
        if @parent_io
          begin
            @parent_io[0].close if @parent_io[0] and !@parent_io[0].closed?
          rescue IOError
          end
        end

        if @parent_io[1]
          if opts[:stdout_size] and opts[:stdout_size] > 0
            @stdout = @parent_io[1].read(opts[:stdout_size]) unless @parent_io[1].closed?
            emptypipes = false if !@parent_io[1].closed? and !@parent_io[1].eof?
            unless @parent_io[1].closed?
              begin
                @parent_io[1].readpartial(4096) while true
              rescue EOFError
              end
            end
          else
            @stdout = @parent_io[1].read unless @parent_io[1].closed?
          end
        end

        if @parent_io[2]
          if opts[:stderr_size] and opts[:stderr_size] > 0
            @stderr = @parent_io[2].read(opts[:stderr_size]) unless @parent_io[2].closed?
            emptypipes = false if !@parent_io[2].closed? and !@parent_io[2].eof?
            unless @parent_io[2].closed?
              begin
                @parent_io[2].readpartial(4096) while true
              rescue EOFError
              end
            end
          else
            @stderr = @parent_io[2].read unless @parent_io[2].closed?
          end
        end
        _, @status = Process.wait2(@exec_pid)
        @exec_pid = nil
      ensure
        if @exec_pid # Process.wait2 did not finish, the current thread was probably killed
          kill()
          begin
            _, @status = Process.wait2(@exec_pid)
          rescue Errno::ESRCH
          end
          @exec_pid = nil
        else
          @kill_lock.synchronize do
            @parent_io.each do |io|
              begin
                io.close if io and !io.closed?
              rescue IOError
              end
            end if @parent_io
          end
        end
        raise SignalException.new(@status.termsig) if @status and @status.signaled?
      end

      raise KadeployExecuteError.new(
        "Command #{@command.inspect} exited with status #{@status.exitstatus}"
      ) if opts[:checkstatus] and !@status.success?

      [ @status, @stdout, @stderr, emptypipes ]
    end
  end

  EXECDEBUG = false
  # kill a tree of processes. The killing is done in three steps:
  # 1) STOP the target process
  # 2) recursively kill all children
  # 3) KILL the target process
  def self.kill_recursive(pid)
    puts "Killing PID #{pid} from PID #{$$}" if EXECDEBUG

    # SIGSTOPs the process to avoid it creating new children
    begin
      Process.kill('STOP',pid)
    rescue Errno::ESRCH # "no such process". The process was already killed, return.
      puts "got ESRCH on STOP" if EXECDEBUG
      return
    end
    # Gather the list of children before killing the parent in order to
    # be able to kill children that will be re-attached to init
    children = `ps --ppid #{pid} -o pid=`.split("\n").collect!{|p| p.strip.to_i}
    children.compact!
    puts "Children: #{children}" if EXECDEBUG
    # Check that the process still exists
    # Directly kill the process not to generate <defunct> children
    children.each do |cpid|
      kill_recursive(cpid)
    end if children

    begin
      Process.kill('KILL',pid)
    rescue Errno::ESRCH # "no such process". The process was already killed, return.
      puts "got ESRCH on KILL" if EXECDEBUG
      return
    end
  end

  def kill()
    @kill_lock.synchronize{ kill! }
  end

  def kill!()
    unless @exec_pid.nil?
      Execute.kill_recursive(@exec_pid)
      # This function do not wait the PID since the thread that use wait() is supposed to be running and to do so
    end

    @parent_io.each do |io|
      begin
        io.close if io and !io.closed?
      rescue IOError
      end
    end if @parent_io

    @child_io.each do |io|
      begin
        io.close if io and !io.closed?
      rescue IOError
      end
    end if @child_io
  end

  def self.do(*cmd,&block)
    exec = Execute[*cmd]
    if block_given?
      exec.run(nil,Proc.new)
    else
      exec.run()
    end
  end
end

end
