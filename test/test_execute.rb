#!/usr/bin/env ruby

require_relative '../lib/kadeploy3/common/execute'
require_relative '../lib/kadeploy3/common/error'
require 'test/unit'
require 'tempfile'
require 'tmpdir'
require 'pp'

class Execute_test < Test::Unit::TestCase

  def prepare_file()
    @file = Tempfile.new("testons")
    1.upto(100) {|i| @file.puts i}
    @file.close()
    @cmd=['cat',@file.path]
    @cmd2=['bash','-c',"cat #{@file.path} >&2"]
  end
  def test_execute()
    prepare_file()
    run = Kadeploy::Execute[*@cmd].run!()
    res = run.wait()
    file = File.read(@file.path)
    assert_equal(file,run.stdout)
    assert(run.emptypipes,"pipes are empty")
    assert(res[3],"pipes are empty")
  end
  def test_execute2()
    prepare_file()
    run = Kadeploy::Execute[*@cmd].run!()
    res = run.wait()
    file = File.read(@file.path)
    assert_equal(file,res[1])
    assert(res[3],"pipes are empty")
  end
  def test_execute_err()
    prepare_file()
    run = Kadeploy::Execute[*@cmd2].run!()
    run.wait()
    file = File.read(@file.path)
    assert_equal(file,run.stderr)
    assert(run.emptypipes,"pipes are empty")
  end
  def test_execute2_err()
    prepare_file()
    run = Kadeploy::Execute[*@cmd2].run!()
    res = run.wait()
    file = File.read(@file.path)
    assert_equal(file,res[2])
    assert(res[3],"pipes are empty")
  end
  def test_execute_limit_stdout()
    prepare_file()
    run = Kadeploy::Execute[*@cmd].run!(:stdout_size=>5)
    run.wait()
    assert_equal("1\n2\n3",run.stdout)
    assert(!run.emptypipes,"pipes are not empty")
  end
  def test_execute_limit_stderr()
    prepare_file()
    run = Kadeploy::Execute[*@cmd2].run!(:stderr_size=>5)
    run.wait()
    assert_equal("1\n2\n3",run.stderr)
    assert(!run.emptypipes,"pipes are not empty")
  end
  def test_stdin()
    run = Kadeploy::Execute['ruby'].run!({:stdin=>true})
    run.write_stdin('puts 2+2*2;puts Math.cos(Math::PI)')
    run.wait()
    assert_equal("6\n-1.0\n",run.stdout)
  end
  def test_signaled()
    run = Kadeploy::Execute["sleep","10"].run!()
    sleep(0.2)
    Process.kill("SIGKILL",run.exec_pid)
    assert_raise(SignalException) do
      run.wait()
    end
  end
  def test_signaled_multithread()
    run = Kadeploy::Execute["sleep","10"].run!()
    sleep(0.2)
    Process.kill("SIGKILL",run.exec_pid)
    t1 = Thread.new do
      assert_raise(SignalException) do
        run.wait()
      end
    end
    t2 = Thread.new do
      assert_raise(SignalException) do
        run.wait()
      end
    end
    t1.join
    t2.join
  end
  def test_non_null_exit
    run = Kadeploy::Execute["ls","/zoefkzoifjauifhiagier"].run!()
    assert_raise(Kadeploy::KadeployExecuteError) do
      run.wait()
    end
    assert_equal(2,run.status.exitstatus)
  end
  def test_non_null_exit_ignored
    run = Kadeploy::Execute["ls","/zoefkzoifjauifhiagier"].run!()
    assert_nothing_raised do
      run.wait({})
    end
    assert_equal(2,run.status.exitstatus)
  end
  def test_non_null_exit_multithread
    run = Kadeploy::Execute["ls","/zoefkzoifjauifhiagier"].run!()
    t1 = Thread.new do
      assert_raise(Kadeploy::KadeployExecuteError) do
        run.wait()
      end
    end
    t2 = Thread.new do
      assert_raise(Kadeploy::KadeployExecuteError) do
        run.wait()
      end
    end
    t1.join
    t2.join
    assert_equal(2,run.status.exitstatus)
  end
  def test_kill()
    run = Kadeploy::Execute["sleep","3"].run!()
    run.kill
    assert_nothing_raised(SignalException) do
      run.wait()
    end
    assert(run.status.signaled?,"The process must be killed")
  end
  def test_kill2()
    run = Kadeploy::Execute["sleep","3"].run!()
    run.kill
    res = nil
    assert_nothing_raised(SignalException) do
      res = run.wait()
    end
    assert(res[0].signaled?,"The process must be killed")
  end

  def test_kill_multithread()
    run = Kadeploy::Execute["sleep","3"].run!()
    t1 = Thread.new do
      assert_nothing_raised(SignalException) do
        run.wait()
      end
    end
    t2 = Thread.new do
      assert_nothing_raised(SignalException) do
        run.wait()
      end
    end
    run.kill
    t1.join
    t2.join
    assert(run.status.signaled?,"The process must be killed")
  end
  def test_stderr_after_kill()
    run = Kadeploy::Execute["bash","-c","echo toto >&2;sleep 5"].run!()
    t1 = Thread.new do
      assert_nothing_raised(SignalException) do
        run.wait()
      end
    end
    sleep(0.2)
    t1.kill
    assert_nothing_raised(SignalException) do
      t1.join
    end
    assert_equal("toto\n",run.stderr)
    assert(run.status.signaled?,"The process must be killed")
  end
  def test_output_after_kill()
    run = Kadeploy::Execute["bash","-c","echo toto;sleep 5"].run!()
    t1 = Thread.new do
      assert_nothing_raised(SignalException) do
        run.wait()
      end
    end
    sleep(0.2)
    t1.kill
    assert_nothing_raised(SignalException) do
      t1.join
    end
    assert_equal("toto\n",run.stdout)
    assert(run.status.signaled?,"The process must be killed")
  end
  def test_kill_thread()
    run = Kadeploy::Execute["sleep","3"].run!()
    t1 = Thread.new do
      assert_nothing_raised(SignalException) do
        run.wait()
      end
    end
    sleep(0.2)
    t1.kill()
    assert_nothing_raised(SignalException) do
      t1.join()
    end
    assert(run.status.signaled?,"The process must be killed")
  end

  def test_kill_thread_multithread()
    run = Kadeploy::Execute["sleep","3"].run!()
    t1 = Thread.new do
      assert_nothing_raised(SignalException) do
        run.wait()
      end
    end
    t2 = Thread.new do
      assert_nothing_raised(SignalException) do
        run.wait()
      end
    end
    sleep(0.2)
    t1.kill()
    assert_nothing_raised(SignalException) do
      t1.join()
    end
    t2.join()
    assert(run.status.signaled?,"The process must be killed")
  end
  def test_nopipe
    run = Kadeploy::Execute["sleep","100"].run!(:stdout=>false,:stderr=>false,:stdin=>false)
    sleep(0.2) #wait for fork finish the job
    assert_equal("/dev/null",File.readlink("/proc/#{run.exec_pid}/fd/0"),"fd0")
    assert_equal("/dev/null",File.readlink("/proc/#{run.exec_pid}/fd/1"),"fd1")
    assert_equal("/dev/null",File.readlink("/proc/#{run.exec_pid}/fd/2"),"fd2")
    run.kill()
    run.wait()
  end
  def test_fd_leak
    fd=File.open("/dev/urandom")
    file=Tempfile.new("testpipeleak")
    file.puts("#!/usr/bin/env ruby")
    file.puts("exit(IO.new(#{fd.fileno}).closed? ? 0 : 10) rescue Exception")
    file.close()
    assert_nothing_raised do
      Kadeploy::Execute['ruby',file.path].run!().wait()
    end
    fd.close()
  end
end
