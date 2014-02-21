$:.unshift File.dirname(__FILE__)
require 'ka_test_case'
require 'test/unit'
require 'tempfile'
require 'socket'
require 'json'

class TestKareboot  < Test::Unit::TestCase
  include KaTestCase

  def setup
    load_config()
    @binary = @binaries[:kareboot]
    @kind = 'simple'
    @env = @envs[:base]
    @part = '3'
  end

  def run_kareboot(*options)
    options += ['-f',@nodefile]
    options += ['-r',@kind] if @kind
    options << '--force'

    run_ka_nodelist(@binary,*options)
  end

  def test_simple
    run_kareboot()

    begin
      sock = TCPSocket.new(@nodes.first,25300)
      sock.close
      assert(false,'Node booted on deployment environment')
    rescue
    end

    begin
      sock = TCPSocket.new(@nodes.first,22)
      sock.close
    rescue
      assert(false,'Node do not listen on SSH port')
    end
  end

  def test_set_pxe
    desc = env_desc(@env)

    envtgz = desc['image']['file']
    vmlinuz = desc['boot']['kernel']
    initrd = desc['boot']['initrd']

    tmpdir = Dir.mktmpdir
    pxeprofile = Tempfile.new('pxe_profile')
    begin
      `cp #{envtgz} #{tmpdir}`
      `(cd #{tmpdir}; tar zxf #{File.basename(envtgz)} &> /dev/null)`
      kernelfile = File.join(tmpdir,vmlinuz)
      kernelfile = File.join(tmpdir,`readlink #{kernelfile}`.strip)
      initrdfile = File.join(tmpdir,initrd)
      initrdfile = File.join(tmpdir,`readlink #{initrdfile}`.strip)

      pxeprofile.write(
        "PROMPT 1\n"\
        "SERIAL 0 19200\n"\
        "DEFAULT bootlabel\n"\
        "DISPLAY messages\n"\
        "TIMEOUT 50\n"\
        "label bootlabel\n"\
        "  KERNEL KERNELS_DIR/FILES_PREFIX--#{File.basename(kernelfile)}\n"\
        "  APPEND initrd=KERNELS_DIR/FILES_PREFIX--#{File.basename(initrdfile)} root=/dev/sda3\n"
      )
      pxeprofile.close

      @kind = 'set_pxe'
      run_kareboot('-w',pxeprofile.path,'-x',"#{kernelfile},#{initrdfile}")
    ensure
      FileUtils.remove_entry_secure(tmpdir)
      pxeprofile.unlink
    end
  end

  def test_set_pxe_singularity
  end

  def test_deploy_env
    @kind = 'deploy_env'
    run_kareboot()
    begin
      sock = TCPSocket.new(@nodes.first,25300)
      sock.close
      sock = TCPSocket.new(@nodes.first,22)
      sock.close
    rescue
      assert(false,'Node did not boot on deployment environment')
    end
  end

  def test_env_recorded
    @kind = 'recorded_env'
    part = 3
    run_ka(@binaries[:kadeploy],'-e',@env,'-f',@nodefile,'-p',@part,'-k'){}
    run_kareboot('-e',@env,'-p',@part)
  end

  def test_check_destructive
  end

  def test_end_hook
    widfile = Tempfile.new('wid')
    run_kareboot('--hook','--write-workflow-id',widfile.path)
    assert(File.exist?(widfile.path),"WID file not found")
    wid = File.read(widfile.path).strip
    file = '/tmp/test-hook-end_of_reboot'
    assert(File.exist?(file),"#{file} file not found")
    begin
      status = JSON.parse(File.read(file))
      assert(status['wid'] == wid,"Invalid WID")
      assert(status['done'],"Operation not done when executing the hook")
    rescue JSON::ParserError
      assert(false,"#{file} invalid file, JSON error")
    ensure
      widfile.unlink
    end
  end
end

