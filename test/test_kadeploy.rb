$:.unshift File.dirname(__FILE__)
require 'ka_test_case'
require 'test/unit'
require 'tempfile'
require 'tmpdir'
require 'yaml'
require 'json'
require 'rubygems'
require 'net/ssh'

class TestKadeploy < Test::Unit::TestCase
  include KaTestCase

  def setup
    load_config()
    @binary = @binaries[:kadeploy]
    @env = @envs[:base]
    @user = nil
    @key = true
    @connect = true
  end

  def run_kadeploy(*options)
    options += ['-f',@nodefile]
    options += ['-u',@user] if @user
    options += ['-e',@env] if @env
    options << '-k' if @key
    options << '--force'

    run_ka_nodelist(@binary,*options)

    connect_test(@nodes.first) if @connect
  end

  def test_simple
    run_kadeploy()
  end

  def test_multi_server
    run_kadeploy('--multi-server')
  end

  def test_vlan
    if @vlan
      @connect = false
      run_kadeploy('--vlan',@vlan)
    else # in kaboostrap
      run_kadeploy('--vlan','1')
      begin
        str = File.read('/tmp/test-vlan').strip
        assert(str == "test 1 #{USER}","Invalid VLAN test file")
      rescue
        assert(false,"VLAN test file not found")
      end
    end
  end

  def test_breakpoint
    @connect = false
    run_kadeploy('--breakpoint','SetDeploymentEnvUntrusted:reboot')
  end

  def test_reformat_tmp
    run_kadeploy('--reformat-tmp','ext3')
  end

  def test_force_steps
    run_kadeploy('--force-steps','SetDeploymentEnv|SetDeploymentEnvUntrusted:1:300&BroadcastEnv|BroadcastEnvKastafior:1:200&BootNewEnv|BootNewEnvClassical:1:200,BootNewEnvHardReboot:1:200')
  end

  def test_env_shared
    desc = env_desc(@env)
    desc['name'] = @tmp[:envname]
    desc['visibility'] = 'shared'

    envfile = Tempfile.new('env')
    envfile.write(desc.to_yaml)
    envfile.close

    begin
      run_ka(@binaries[:kaenv],'-a',envfile.path){}
      @env = @tmp[:envname]
      run_kadeploy('-e',@tmp[:envname])
    ensure
      run_ka(@binaries[:kaenv],'-d',@tmp[:envname]){}
      envfile.unlink
    end
  end

  def test_env_private
    desc = env_desc(@env)
    desc['name'] = @tmp[:envname]
    desc['visibility'] = 'private'

    envfile = Tempfile.new('env')
    envfile.write(desc.to_yaml)
    envfile.close

    begin
      run_ka(@binaries[:kaenv],'-a',envfile.path){}
      @env = @tmp[:envname]
      run_kadeploy()
    ensure
      run_ka(@binaries[:kaenv],'-d',@tmp[:envname]){}
      envfile.unlink
    end
  end

  def test_env_anon_nfs
    desc = env_desc(@envs[:nfs])
    desc['visibility'] = 'private'

    envfile = Tempfile.new('env')
    envfile.write(desc.to_yaml)
    envfile.close

    begin
      @env = nil
      run_kadeploy('-a',envfile.path)
    ensure
      envfile.unlink
    end
  end

  def test_env_anon_http
    desc = env_desc(@envs[:http])
    desc['visibility'] = 'private'

    envfile = Tempfile.new('env')
    envfile.write(desc.to_yaml)
    envfile.close

    begin
      @env = nil
      run_kadeploy('-a',envfile.path)
    ensure
      envfile.unlink
    end
  end

  def test_env_anon_server
    desc = env_desc(@env)
    desc['name'] = @tmp[:envname]
    desc['visibility'] = 'shared'
    desc['image']['file'] = 'server://' + desc['image']['file']
    desc['postinstalls'].each do |post|
      post['archive'] = 'server://' + post['archive']
    end

    envfile = Tempfile.new('env')
    envfile.write(desc.to_yaml)
    envfile.close

    begin
      @env = nil
      run_kadeploy('-a',envfile.path)
    ensure
      envfile.unlink
    end
  end

  def test_env_rec_http
    @env = @envs[:http]
    run_kadeploy()
  end

  def test_env_rec_nfs
    @env = @envs[:nfs]
    run_kadeploy()
  end

  def test_env_rec_server
    desc = env_desc(@env)
    desc['name'] = @tmp[:envname]
    desc['visibility'] = 'shared'
    desc['image']['file'] = 'server://' + desc['image']['file']
    desc['postinstalls'].each do |post|
      post['archive'] = 'server://' + post['archive']
    end

    envfile = Tempfile.new('env')
    envfile.write(desc.to_yaml)
    envfile.close

    begin
      run_ka(@binaries[:kaenv],'-a',envfile.path){}
      @env = @tmp[:envname]
      run_kadeploy()
    ensure
      run_ka(@binaries[:kaenv],'-d',@tmp[:envname]){}
      envfile.unlink
    end
  end

  def test_env_xen
    @env = @envs[:xen]
    run_kadeploy()
  end

  def test_env_version
    desc = env_desc(@env)
    desc['name'] = @tmp[:envname]
    desc['version'] = 1
    desc['visibility'] = 'private'

    envfile = Tempfile.new('env')
    envfile.write(desc.to_yaml)
    envfile.close

    begin
      run_ka(@binaries[:kaenv],'-a',envfile.path){}
      @env = @tmp[:envname]
      run_kadeploy('--env-version','1')
    ensure
      run_ka(@binaries[:kaenv],'-d',@tmp[:envname]){}
      envfile.unlink
    end
  end

  def test_disable_bootloader
    @env = @envs[:grub]
    run_kadeploy('--disable-bootloader-install')
  end

  def test_disable_disk_partitioning
    run_kadeploy('--disable-disk-partitioning')
  end

  def test_custom_preinstall
    scriptfile = Tempfile.new('script_file')
    partfile = Tempfile.new('partition_file')
    tgzfile = `tempfile`.strip

    scriptfile.write(
      "#!/bin/bash -e\n"\
      "cat ${KADEPLOY_PREPOST_EXTRACTION_DIR}/#{File.basename(partfile.path)} | fdisk ${KADEPLOY_BLOCK_DEVICE}\n"\
      "partprobe ${KADEPLOY_BLOCK_DEVICE}\n"\
      "sleep 2\n"\
      "mkswap ${KADEPLOY_BLOCK_DEVICE}${KADEPLOY_SWAP_PART_NUM}\n"\
      "mkdir -p ${KADEPLOY_ENV_EXTRACTION_DIR}\n"\
      "mkfs -t ext3 ${KADEPLOY_DEPLOY_PART}\n"\
      "mount ${KADEPLOY_DEPLOY_PART} ${KADEPLOY_ENV_EXTRACTION_DIR}\n"\
      "echo OK > ${KADEPLOY_ENV_EXTRACTION_DIR}/TEST\n"
    )
    `chmod +x #{scriptfile.path}`
    scriptfile.close

    partfile.write("d\n1\nd\n2\nd\n3\nd\n4\nn\np\n1\n\n+4G\nt\n82\nn\np\n2\n\n+6G\nt\n2\n83\nn\np\n3\n\n+6G\nt\n3\n83\nw\n")
    partfile.close

    `tar czf #{tgzfile} -C #{File.dirname(scriptfile.path)} #{File.basename(scriptfile.path)} #{File.basename(partfile.path)}`

    desc = env_desc(@env)
    desc['visibility'] = 'private'
    desc['preinstall'] = {}
    desc['preinstall']['archive'] = tgzfile
    desc['preinstall']['compression'] = 'gzip'
    desc['preinstall']['script'] = File.basename(scriptfile.path)

    envfile = Tempfile.new('env')
    envfile.write(desc.to_yaml)
    envfile.close

    res = ''
    begin
      @env = nil
      run_kadeploy('-a',envfile.path)

      begin
        Net::SSH.start(@nodes.first,'root') do |ssh|
          res = ssh.exec!('cat /TEST').strip
        end
      rescue Net::SSH::AuthenticationFailed, SocketError
        assert(false,'Unable to contact nodes')
      end
      assert(res == 'OK','Custom pre-install did not work properly')
    ensure
      scriptfile.unlink
      partfile.unlink
      `rm #{tgzfile}`
      envfile.unlink
    end
  end

  def test_custom_pxe
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

      run_kadeploy('-w',pxeprofile.path,'-x',"#{kernelfile},#{initrdfile}")
    ensure
      FileUtils.remove_entry_secure(tmpdir)
      pxeprofile.unlink
    end
  end

  def test_custom_operations
    `echo OK > #{@tmp[:localfile]}`
    scriptfile = Tempfile.new('script')
    scriptfile.write(
      "#!/bin/bash\n"\
      "echo OK > ${KADEPLOY_ENV_EXTRACTION_DIR}/TEST_RUN\n"
    )
    scriptfile.close

    opsfile = Tempfile.new('ops')
    ops = {
      'SetDeploymentEnvUntrusted' => {
        'mount_deploy_part' => {
          'substitute' => [
            {
              'action' => 'exec',
              'name' => 'test-exec',
              'command' => 'mount ${KADEPLOY_DEPLOY_PART} ${KADEPLOY_ENV_EXTRACTION_DIR}; partprobe ${KADEPLOY_BLOCK_DEVICE}',
            }
          ],
          'post-ops' => [
            {
              'action' => 'send',
              'name' => 'test-send',
              'file' => @tmp[:localfile],
              'destination' => '/mnt/dest',
              'scattering' => 'tree',
            }
          ]
        }
      },
      'BroadcastEnvKastafior' => {
        'send_environment' => {
          'pre-ops' => [
            {
              'action' => 'exec',
              'name' => 'test-exec',
              'command' => 'echo OK > ${KADEPLOY_ENV_EXTRACTION_DIR}/TEST_EXEC',
            }
          ],
          'post-ops' => [
            {
              'action' => 'run',
              'name' => 'test-run',
              'file' => scriptfile.path,
            }
          ],
        }
      }
    }
    opsfile.write(ops.to_yaml)
    opsfile.close

    begin
      run_kadeploy('--custom-steps',opsfile.path)

      pre = ''
      post = ''
      exe = ''
      send = ''
      run = ''
      begin
        Net::SSH.start(@nodes.first,'root') do |ssh|
          exe = ssh.exec!('cat /TEST_EXEC').strip
          send = ssh.exec!("cat /#{File.basename(@tmp[:localfile])}").strip
          run = ssh.exec!('cat /TEST_RUN').strip
        end
      rescue Net::SSH::AuthenticationFailed, SocketError
        assert(false,'Unable to contact nodes')
      end
      assert(exe == 'OK','Custom exec action does not work properly')
      assert(send == 'OK','Custom send action does not work properly')
      assert(run == 'OK','Custom run action does not work properly')
    ensure
      `rm #{@tmp[:localfile]}`
      scriptfile.unlink
      opsfile.unlink
    end
  end

  def test_end_hook
    widfile = Tempfile.new('wid')
    run_kadeploy('--hook','--write-workflow-id',widfile.path)
    assert(File.exist?(widfile.path),"WID file not found")
    wid = File.read(widfile.path).strip
    file = '/tmp/test-hook-end_of_deployment'
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
