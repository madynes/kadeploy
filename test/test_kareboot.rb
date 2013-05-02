require 'ka_test_case'
require 'test/unit'
require 'tempfile'
require 'socket'

class TestKareboot  < Test::Unit::TestCase
  include KaTestCase

  def setup
    load_config()
    @binary = @binaries[:kareboot]
    @kind = 'simple_reboot'
    @env = @envs[:base]
  end

  def run_kareboot(*options)
    options += ['-f',@nodefile]
    options += ['-r',@kind] if @kind

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

  def test_async
    @async = true
    name = 'kareboot'
    binary = Tempfile.new("#{name}-async_")
    binary.write(`cat $(which #{@binary}) | sed s/#{name}.rb/#{name}_async.rb/g`)
    binary.close
    `chmod +x #{binary.path}`

    begin
      @binary = binary.path
      run_kareboot()
    ensure
      binary.unlink
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
  end

  def test_check_prod_env
  end
end

