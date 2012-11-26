require 'ka_test_case'
require 'test/unit'
require 'tempfile'
require 'tmpdir'
require 'yaml'
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
    options << '--ignore-nodes-deploying'

    run_ka_check(@binary,*options)

    connect_test(@nodes.first) if @connect
  end

  def test_simple
    run_kadeploy()
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

    tmp = desc.split("\n")
    tmp.delete_if { |line| line =~ /^name\s*:.*$/ }
    tmp << "name : #{@tmp[:envname]}"
    tmp.delete_if { |line| line =~ /^visibility\s*:.*$/ }
    tmp << 'visibility : shared'

    desc = tmp.join("\n")
    envfile = Tempfile.new('env')
    envfile.write(desc)
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

    tmp = desc.split("\n")
    tmp.delete_if { |line| line =~ /^name\s*:.*$/ }
    tmp << "name : #{@tmp[:envname]}"
    tmp.delete_if { |line| line =~ /^visibility\s*:.*$/ }
    tmp << 'visibility : private'

    desc = tmp.join("\n")
    envfile = Tempfile.new('env')
    envfile.write(desc)
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

    tmp = desc.split("\n")
    tmp.delete_if { |line| line =~ /^visibility\s*:.*$/ }
    tmp << 'visibility : private'

    desc = tmp.join("\n")
    envfile = Tempfile.new('env')
    envfile.write(desc)
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

    tmp = desc.split("\n")
    tmp.delete_if { |line| line =~ /^visibility\s*:.*$/ }
    tmp << 'visibility : private'

    desc = tmp.join("\n")
    envfile = Tempfile.new('env')
    envfile.write(desc)
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

  def test_env_xen
    @env = @envs[:xen]
    run_kadeploy()
  end

  def test_async
    @async = true
    @key = false
    @connect = false

    name = 'kadeploy_client'
    binary = Tempfile.new("#{name}-async_")
    binary.write(`cat $(which #{@binary}) | sed s/#{name}.rb/#{name}_async.rb/g`)
    binary.close
    `chmod +x #{binary.path}`

    begin
      @binary = binary.path
      run_kadeploy()
    ensure
      binary.unlink
    end
  end

  def test_env_version
    desc = env_desc(@env)

    tmp = desc.split("\n")
    tmp.delete_if { |line| line =~ /^name\s*:.*$/ }
    tmp << "name : #{@tmp[:envname]}"
    tmp.delete_if { |line| line =~ /^version\s*:.*$/ }
    tmp << 'version : 1'
    tmp.delete_if { |line| line =~ /^visibility\s*:.*$/ }
    tmp << 'visibility : private'

    desc = tmp.join("\n")
    envfile = Tempfile.new('env')
    envfile.write(desc)
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
    run_kadeploy('--disable-bootloader')
  end

  def test_disable_disk_partitioning
    run_kadeploy('--disable-disk-partitioning')
  end

  def test_custom_preinstall
    scriptfile = Tempfile.new('script_file')
    partfile = Tempfile.new('partition_file')
    tgzfile = `tempfile`.strip

    scriptfile.write(
      "#!/bin/sh\n"\
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

    partfile.write("d\n1\nd\n2\nd\n3\nd\n4\nn\np\n1\n\n+6G\nt\n82\nn\np\n2\n\n+20G\nt\n2\n83\nn\np\n3\n\n\nt\n3\n83\nw\n")
    partfile.close

    `tar czf #{tgzfile} -C #{File.dirname(scriptfile.path)} #{File.basename(scriptfile.path)} #{File.basename(partfile.path)}`

    desc = env_desc(@env)

    tmp = desc.split("\n")
    tmp.delete_if { |line| line =~ /^visibility\s*:.*$/ }
    tmp << 'visibility : private'
    tmp.delete_if { |line| line =~ /^preinstall\s*:.*$/ }
    tmp << "preinstall : #{tgzfile}|tgz|#{File.basename(scriptfile.path)}"

    desc = tmp.join("\n")
    envfile = Tempfile.new('env')
    envfile.write(desc)
    envfile.close

    res = ''
    begin
      @env = nil
      run_kadeploy('-a',envfile.path,'-V4','--debug')

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

    tmp = desc.split("\n")
    envtgz = tmp.select{ |line| line =~ /^tarball\s*:.*$/ }[0].split(':',2)[1].split('|')[0].strip
    vmlinuz = tmp.select{ |line| line =~ /^kernel\s*:.*$/ }[0].split(':',2)[1].strip
    initrd = tmp.select{ |line| line =~ /^initrd\s*:.*$/ }[0].split(':',2)[1].strip

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
    tmpfile = Tempfile.new('tmp')
    opsfile = Tempfile.new('ops')
    tmpfile.write('OK')
    tmpfile.close

    ops = {
      'SetDeploymentEnvUntrusted' => {
        'mount_deploy_part' => {
          'substitute' => [
            {
              'action' => 'exec',
              'name' => 'test-mount',
              'command' => 'mount ${KADEPLOY_DEPLOY_PART} ${KADEPLOY_ENV_EXTRACTION_DIR}; partprobe ${KADEPLOY_BLOCK_DEVICE}',
            }
          ],
          'post-ops' => [
            {
              'action' => 'send',
              'name' => 'test-send',
              'file' => @tmp[:localfile],
              'destination' => '/mnt/dest/TEST_POST',
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
              'command' => 'echo OK > ${KADEPLOY_ENV_EXTRACTION_DIR}/TEST_PRE',
            }
          ],
        }
      }
    }
    opsfile.write(ops.to_yaml)
    opsfile.close

    begin
      run_kadeploy('--set-custom-operations',opsfile.path)

      pre = ''
      post = ''
      begin
        Net::SSH.start(@nodes.first,'root') do |ssh|
          pre = ssh.exec!('cat /TEST_PRE').strip
          post = ssh.exec!('cat /TEST_POST').strip
        end
      rescue Net::SSH::AuthenticationFailed, SocketError
        assert(false,'Unable to contact nodes')
      end
      assert(pre == 'OK','Custom pre-ops does not work properly')
      assert(post == 'OK','Custom post-ops does not work properly')
    ensure
      `rm #{@tmp[:localfile]}`
      tmpfile.unlink
      opsfile.unlink
    end
  end
end
