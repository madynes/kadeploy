module Kadeploy

  # To be used as you're using Open3.popen3 in ruby 1.9.2
  class Execute
    require 'thread'
    require 'fcntl'
    attr_reader :command, :exec_pid, :stdout, :stderr, :status,:emptypipes
    @@forkmutex = Mutex.new

    def initialize(*cmd)
      @command = *cmd

      @exec_pid = nil

      @stdout = nil
      @stderr = nil
      @status = nil
      @run_thread = nil
      @killed = false

      @child_io = nil
      @parent_io = nil
      @lock = Mutex.new
      @emptypipes = false
    end

    #Free the command, stdout stderr string.
    def free
      @command = nil
      @stdout = nil
      @stderr = nil
    end

    #Same as new function
    def self.[](*cmd)
      self.new(*cmd)
    end

    #Initialize the pipes and return one array for parent and one array for child.
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

    # Launch the command provided by the constructor
    #
    # Arguments
    #   opts: hash
    #     :stdin, :stdout, :stderr  boolean to enable or disable pipe in respectively stdin,stdout and stderr.
    #     :stdout_size, :stderr_size is number to limit the number of byte read by execute respectively on stdout or stderr.
    def run(opts={:stdin => false})
      @lock.synchronize do
        if @run_thread
          raise "Already launched"
        else
          begin
          ensure #We can't interrupt this process here before run was launched.
            @child_io, @parent_io = Execute.init_ios(opts)
            @@forkmutex.synchronize do
              @exec_pid = fork do
                run_fork()
              end
            end
            @run_thread = Thread.new do
              @child_io.each do |io|
                io.close if io and !io.closed?
              end
              @child_io = nil
              emptypipes = true

              @stdout,emptypipes = read_parent_io(1,opts[:stdout_size],emptypipes)
              @stderr,emptypipes = read_parent_io(2,opts[:stderr_size],emptypipes)

              _, @status = Process.wait2(@exec_pid)
              @exec_pid = nil

              @parent_io.each do |io|
                io.close if io and !io.closed?
              end

              @parent_io = nil
              @emptypipes = emptypipes
            end
          end
        end
      end
      [@exec_pid, *@parent_io]
    end

    #Write to stdin
    #Argument:
    #  String passed to process stdin.
    def write_stdin(str)
      @lock.synchronize do
        if @parent_io and @parent_io[0] and !@parent_io[0].closed?
          @parent_io[0].write(str)
        else
          raise "Stdin is closed"
        end
      end
    end

    # Close stdin of programme if it opened.
    def close_stdin()
      @lock.synchronize do
        if @parent_io and @parent_io[0] and !@parent_io[0].closed?
          @parent_io[0].close
          @parent_io[0] = nil
        end
      end
    end

    # Run the command and return the Execute object.
    # Arguments:
    #   Opts see bellow
    def run!(opts={:stdin => false})
      run(opts)
      self
    end


    # Wait the end of process
    #
    # Argument is hash
    # :checkstatus : if it true at end of process it raises an exception if the result is not null.
    #
    # Output
    # Array ( Process::Status, stdout String, stderr String, emptypipe).
    def wait(opts={:checkstatus => true})
      begin
        wkilled=true
        close_stdin()
        @run_thread.join
        wkilled=false
      ensure
        @lock.synchronize do
          if wkilled && !@killed
            kill!()
          end
        end
        @run_thread.join
        if !@killed
          # raise SignalException if the process was terminated by a signal and the kill function was not called.
          raise SignalException.new(@status.termsig) if @status and @status.signaled?
          raise KadeployExecuteError.new(
            "Command #{@command.inspect} exited with status #{@status.exitstatus}"
          ) if opts[:checkstatus] and !@status.success?
        end
      end
      [ @status, @stdout, @stderr, @emptypipes ]
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

    #Kill the launched process.
    def kill()
      @lock.synchronize{ kill! }
    end


    private

    #Launch kill_recurcive if in launched and it not already killed
    #@killed becomes true.
    def kill!()
      if @exec_pid && !@killed
        @killed = true
        Execute.kill_recursive(@exec_pid)
        # This function do not wait the PID since the thread that use wait() is supposed to be running and to do so
      end
    end

    #Read pipe and return out and boolean which indicate if pipe are empty.
    #Arguments:
    #  +num       : number of file descriptor
    #  +size      : Maximum number of bytes must be read 0 is unlimited.
    #  +emptypipes: Previous value of emptypipe the new value was obtained with logical and.
    #Output:
    #  Array (output: String, emptypipes: Boolean)
    def read_parent_io(num,size,emptypipes)
      out=''
      if @parent_io and @parent_io[num]
        if size and size > 0
          out = @parent_io[num].read(size) unless @parent_io[num].closed?
          emptypipes = false if !@parent_io[num].closed? and !@parent_io[num].eof?
          unless @parent_io[num].closed?
              @parent_io[num].readpartial(4096) until @parent_io[num].eof?
          end
        else
          out = @parent_io[num].read unless @parent_io[num].closed?
        end
      end
      [out,emptypipes]
    end
    # This function is made by children.
    # It redirect the stdin,stdout,stderr
    # Close another descriptor if we are in ruby < 2.0
    # And launch the command with exec.
    def run_fork()
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
          Dir.foreach('/proc/self/fd') do |opened_fd|
            begin
              fd=opened_fd.to_i
              if fd>2
                 f_IO=IO.new(fd)
                 f_IO.close if !f_IO.closed?
              end
            rescue Exception
              #Some file descriptor are reserved for the rubyVM.
              #So the function 'IO.new' raises an exception. We ignore that.
            end
          end
        end
        exec(*@command)
      rescue SystemCallError, Exception => e
        STDERR.puts "Fork Error: #{e.message} (#{e.class.name})"
        STDERR.puts e.backtrace
      end
      exit! 1
    end
  end

end
