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
    @binary = @binaries[:kaenv]
    @tgzfile = `tempfile`.strip
    file = `tempfile`.strip
    `dd if=/dev/urandom of=#{file} bs=1M count=4 1>/dev/null 2>/dev/null`
    `tar czf #{@tgzfile} #{file} 1>/dev/null 2>/dev/null`
    `rm #{file}`
  end

  def run_kaenv(*options)
    run_ka(@binary,*options)
  end

  def check_env(name)
    begin
      desc = YAML.load(run_kaenv('-p', name))
      assert(desc['name'] == name,desc)
      return desc
    rescue ArgumentError => ae
      assert(false,ae.message)
    end
    return nil
  end

  def teardown()
    `rm #{@tgzfile}`
  end

  def test_full_desc
    envfile = Tempfile.new('env')
    desc = {
      'name' => @tmp[:envname],
      'version' => 2,
      'description' => 'test',
      'author' => 'me',
      'visibility' => 'private',
      'destructive' => false,
      'os' => 'linux',
      'image' => {
        'file' => @tgzfile,
        'kind' => 'tar',
        'compression' => 'gzip',
      },
      'preinstall' => {
        'archive' => @tgzfile,
        'compression' => 'gzip',
        'script' => 'test.sh',
      },
      'postinstalls' => [
        {
          'archive' => @tgzfile,
          'compression' => 'gzip',
          'script' => 'test.sh',
        },
        {
          'archive' => @tgzfile,
          'compression' => 'gzip',
          'script' => 'none',
        },
      ],
      'boot' => {
        'kernel' => '/vmlinuz',
        'initrd' => '/initrd.img',
        'kernel_params' => 'console=tty0 console=ttyS1,38400n8',
        'hypervisor' => '/hypervisor',
        'hypervisor_params' => 'dom0_mem=1000000',
      },
      'partition_type' => 131,
      'filesystem' => 'ext3',
    }
    envfile.write(desc.to_yaml)
    envfile.close
    run_kaenv('-a', envfile.path)
    check_env(@tmp[:envname])
    run_kaenv('-d', @tmp[:envname])
    envfile.unlink
  end

  def test_min_desc
    envfile = Tempfile.new('env')
    desc = {
      'name' => @tmp[:envname],
      'os' => 'linux',
      'image' => {
        'file' => @tgzfile,
        'kind' => 'dd',
        'compression' => 'gzip',
      },
    }
    envfile.write(desc.to_yaml)
    envfile.close
    run_kaenv('-a', envfile.path)
    check_env(@tmp[:envname])
    run_kaenv('-d', @tmp[:envname])
    envfile.unlink
  end

  def test_print
    envfile = Tempfile.new('env')
    desc = {
      'name' => @tmp[:envname],
      'os' => 'linux',
      'image' => {
        'file' => @tgzfile,
        'kind' => 'dd',
        'compression' => 'gzip',
      },
    }
    envfile.write(desc.to_yaml)
    envfile.close
    run_kaenv('-a', envfile.path)
    envdesc = check_env(@tmp[:envname])
    desc.each_key do |k|
      assert(desc[k] == envdesc[k])
    end
    run_kaenv('-d', @tmp[:envname])
    envfile.unlink
  end

  def test_set_visibility
    envfile = Tempfile.new('env')
    desc = {
      'name' => @tmp[:envname],
      'visibility' => 'private',
      'os' => 'linux',
      'image' => {
        'file' => @tgzfile,
        'kind' => 'dd',
        'compression' => 'gzip',
      },
    }
    envfile.write(desc.to_yaml)
    envfile.close
    run_kaenv('-a', envfile.path)
    run_kaenv('--set-visibility-tag',@tmp[:envname],'-t','shared')
    envdesc = check_env(@tmp[:envname])
    assert(envdesc['visibility'] == 'shared')
    run_kaenv('-d', @tmp[:envname])
    envfile.unlink
  end

  def test_update_md5
    envfile = Tempfile.new('env')
    desc = {
      'name' => @tmp[:envname],
      'visibility' => 'private',
      'os' => 'linux',
      'image' => {
        'file' => @tgzfile,
        'kind' => 'tar',
        'compression' => 'gzip',
      },
      'preinstall' => {
        'archive' => @tgzfile,
        'compression' => 'gzip',
        'script' => 'test.sh',
      },
      'postinstalls' => [
        {
          'archive' => @tgzfile,
          'compression' => 'gzip',
          'script' => 'test.sh',
        },
        {
          'archive' => @tgzfile,
          'compression' => 'gzip',
          'script' => 'none',
        },
      ],
      'boot' => {
        'kernel' => '/vmlinuz',
        'initrd' => '/initrd.img',
      },
      'partition_type' => 131,
      'filesystem' => 'ext3',
    }
    envfile.write(desc.to_yaml)
    envfile.close
    run_kaenv('-a', envfile.path)
    check_env(@tmp[:envname])
    file = `tempfile`.strip
    `dd if=/dev/urandom of=#{file} bs=1M count=2 1>/dev/null 2>/dev/null`
    `tar czf #{@tgzfile} #{file} 1>/dev/null 2>/dev/null`
    `rm #{file}`
    run_kaenv('--update-image-md5',@tmp[:envname])
    run_kaenv('--update-preinstall-md5',@tmp[:envname])
    run_kaenv('--update-postinstall-md5',@tmp[:envname])
    check_env(@tmp[:envname])
    run_kaenv('-d', @tmp[:envname])
    envfile.unlink
  end
end
