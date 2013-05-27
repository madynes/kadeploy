# To be used as you're using Open3.popen3 in ruby 1.9.2
class Execute
  require 'thread'
  require 'fcntl'
  require 'base64'

  attr_reader :command, :exec_pid, :stdout, :stderr, :status
  @@forkmutex = Mutex.new

  def initialize(*cmd)
    rnd = rand()
    stdout =  Base64.encode64(File.read('/dev/urandom',rnd*200)).gsub!("\n",'')
    status = nil
    if rnd > 0.95
      status = 'false'
    else
      status = 'true'
    end
    time = nil
    if rnd < 0.5
      time = 0.5
    elsif rnd < 0.75
      time = 1
    elsif rnd < 0.875
      time = 2
    else
      time = 4
    end
    @command = "sleep #{time}; echo '#{stdout}'; echo '#{Base64.encode64(cmd.inspect).gsub!("\n",'')}' 1>&2; #{status}"

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

  def wait(opts={:checkstatus => false})
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
        @exec_pid = nil
      rescue Errno::ECHILD
        @status = nil
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
    exec = Execute[*cmd]
    if block_given?
      exec.run(nil,Proc.new)
    else
      exec.run()
    end
  end
end
