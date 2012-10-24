require 'ka_test_case'
require 'test/unit'
require 'tempfile'

class TestKadeploy < Test::Unit::TestCase
  include KaTestCase

  def setup
    load_config()
    @binary = @binaries[:kadeploy]
    @env = @envs[:min]
    @user = nil
    @key = false
    @tmpenvname = '_TMP_KATESTSUITE'
  end

  def run_kadeploy(*options)
    options += ['-u',@user] if @user
    options += ['-e',@env] if @env
    options << '-k' if @key
    options << '--ignore-nodes-deploying'

    run_ka_nodelist(@binary,*options)
  end

  def test_simple
    run_kadeploy()
  end

  def test_breakpoint
    run_kadeploy('--breakpoint','SetDeploymentEnvUntrusted:reboot')
  end

  def test_reformat_tmp
    run_kadeploy('--reformat-tmp','ext3')
  end

  def test_force_steps
    run_kadeploy('--force-steps','SetDeploymentEnv|SetDeploymentEnvUntrusted:1:300&BroadcastEnv|BroadcastEnvKastafior:1:200&BootNewEnv|BootNewEnvClassical:1:200,BootNewEnvHardReboot:1:200')
  end

  def test_env_anon_nfs
    desc = run_ka(@binaries[:kaenv],'-p',@envs[:nfs],'-u',@deployuser){}

    tmp = desc.split("\n")
    tmp.delete_if { |line| line =~ /^visibility\s*:.*$/ }
    tmp << 'visibility : private'

    desc = tmp.join("\n")
    envfile = Tempfile.new('env')
    envfile.write(desc)
    envfile.close

    begin
      @env = false
      run_kadeploy('-a',envfile.path)
    ensure
      envfile.unlink
    end
  end

  def test_env_anon_http
    desc = run_ka(@binaries[:kaenv],'-p',@envs[:http]){}

    tmp = desc.split("\n")
    tmp.delete_if { |line| line =~ /^visibility\s*:.*$/ }
    tmp << 'visibility : private'

    desc = tmp.join("\n")
    envfile = Tempfile.new('env')
    envfile.write(desc)
    envfile.close

    begin
      @env = false
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

  def test_async
    kadeploy = Tempfile.new('kadeploy-client-async_')
    kadeploy.write(`cat $(which #{@binary}) | sed s/kadeploy_client.rb/kadeploy_client_async.rb/g`)
    kadeploy.close
    `chmod +x #{kadeploy.path}`

    begin
      @binary = kadeploy.path
      run_kadeploy()
    ensure
      kadeploy.unlink
    end
  end

  def test_env_version
    desc = run_ka(@binaries[:kaenv],'-p',@envs[:min],'-u',@deployuser){}

    tmp = desc.split("\n")
    tmp.delete_if { |line| line =~ /^name\s*:.*$/ }
    tmp << "name : #{@tmpenvname}"
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
      @env = @tmpenvname
      run_kadeploy('-e',@tmpenvname,'--env-version','0')
    ensure
      run_ka(@binaries[:kaenv],'-d',@tmpenvname){}
      envfile.unlink
    end
  end

  def test_disable_bootloader
  end

  def test_disable_partitioning
  end

  def test_custom_preinstall
  end

  def test_custom_pxe
  end

  def test_custom_operations
  end
end
