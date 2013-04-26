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
  end

  def free
    @command = nil
    @exec_pid = nil
    @stdout = nil
    @stderr = nil
    @status = nil
    @child_io = nil
    @parent_io = nil
  end

  def self.[](*cmd)
    self.new(*cmd)
  end

  def self.init_ios(opts={:stdin => false})
    if opts[:stdin]
      in_r, in_w = IO::pipe
      in_w.sync = true

      out_r, out_w = IO::pipe
      err_r, err_w = IO::pipe

      [ [in_r,out_w,err_w], [in_w,out_r,err_r] ]
    else
      out_r, out_w = IO::pipe
      err_r, err_w = IO::pipe

      [ [nil,out_w,err_w], [nil,out_r,err_r] ]
    end
  end

  def run(opts={:stdin => false})
    @@forkmutex.synchronize do
      @child_io, @parent_io = Execute.init_ios(opts)
      @parent_io.each { |io| io.fcntl(Fcntl::F_SETFD, Fcntl::FD_CLOEXEC) if io }
      @exec_pid = fork {
        @parent_io.each do |io|
          begin
            io.close if io and !io.closed?
          rescue IOError
          end
        end

        std = nil
        if opts[:stdin]
          std = [STDIN, STDOUT, STDERR]
        else
          std = [nil, STDOUT, STDERR]
        end

        std.each_index do |i|
          next unless std[i]
          std[i].reopen(@child_io[i])
          begin
            @child_io[i].close
          rescue IOError
          end
        end
        exec(*@command)
      }

      @child_io.each do |io|
        begin
          io.close if io and !io.closed?
        rescue IOError
        end
      end
    end
    result = [@exec_pid, *@parent_io]
    if block_given?
      begin
        return yield(*result)
      ensure
        wait(opts)
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

  def wait(opts={:checkstatus => true})
    unless @exec_pid.nil?
      begin
        begin
          @parent_io[0].close if @parent_io[0] and !@parent_io[0].closed?
        rescue IOError
        end

        if opts[:stdout_size]
          @stdout = @parent_io[1].read(opts[:stdout_size]) unless @parent_io[1].closed?
          @parent_io[1].read unless @parent_io[1].closed?
        else
          @stdout = @parent_io[1].read unless @parent_io[1].closed?
        end

        if opts[:stderr_size]
          @stderr = @parent_io[2].read(opts[:stderr_size]) unless @parent_io[2].closed?
          @parent_io[2].read unless @parent_io[2].closed?
        else
          @stderr = @parent_io[2].read unless @parent_io[2].closed?
        end

        _, @status = Process.wait2(@exec_pid)
      rescue Errno::ECHILD
        @status = nil
      ensure
        @parent_io.each do |io|
          begin
            io.close if io and !io.closed?
          rescue IOError
          end
        end
        @child_io = nil
        @parent_io = nil
        @exec_pid = nil
      end
      raise KadeployExecuteError.new(
        "Command #{@command.inspect} exited with status #{@status.exitstatus}"
      ) if opts[:checkstatus] and !@status.success?
      [ @status, @stdout, @stderr ]
    end
  end

  def self.kill_recursive(pid)
    begin
      # SIGSTOPs the process to avoid it creating new children
      Process.kill('STOP',pid)
      # Gather the list of children before killing the parent in order to
      # be able to kill children that will be re-attached to init
      children = `ps --ppid #{pid} -o pid=`.split("\n").collect!{|p| p.strip.to_i}
      # Directly kill the process not to generate <defunct> children
      Process.kill('KILL',pid)
      children.each do |cpid|
        kill_recursive(cpid)
      end
    rescue Errno::ESRCH
    end
  end

  def kill()
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

    unless @exec_pid.nil?
      begin
        Execute.kill_recursive(@exec_pid)
        Process.wait(@exec_pid)
      rescue Errno::ESRCH
      end
      @exec_pid = nil
    end
    free()
  end

  def self.do(*cmd,&block)
    child_io, parent_io = init_ios()

    pid = fork {
      parent_io.each { |io| io.close }
      std = [STDIN, STDOUT, STDERR]
      std.each_index do |i|
        std[i].reopen(child_io[i])
        child_io[i].close
      end
      exec(*cmd)
    }

    child_io.each { |io| io.close }
    result = [pid, *parent_io]
    if block_given?
      begin
        return yield(*result)
      ensure
        parent_io.each { |io| io.close unless io.closed? }
        begin
          Process.wait(pid)
        rescue Errno::ECHILD
        end
      end
    end
    result
  end
end
