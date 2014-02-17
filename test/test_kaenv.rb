# encoding: utf-8
$:.unshift File.dirname(__FILE__)
require 'ka_test_case'
require 'test/unit'
require 'tempfile'
require 'tmpdir'
require 'yaml'

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

  def check_env(name,version=nil)
    begin
      opts = ['-p',name]
      opts += ['--env-version',version.to_s] if version
      desc = YAML.load(run_kaenv(*opts))
      assert(desc['name'] == name,"Wrong description #{desc.inspect}")
      return desc
    rescue ArgumentError => ae
      run_kaenv('-d', @tmp[:envname])
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
    check_env(@tmp[:envname],2)
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

  def test_update_checksum
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
    run_kaenv('--update-image-checksum',@tmp[:envname])
    run_kaenv('--update-preinstall-checksum',@tmp[:envname])
    run_kaenv('--update-postinstall-checksum',@tmp[:envname])
    check_env(@tmp[:envname])
    run_kaenv('-d', @tmp[:envname])
    envfile.unlink
  end

  def test_charset
    envfile = Tempfile.new('env')
    str = "ĶåđėƥŁŏŷ"
    name = "#{@tmp[:envname]}-#{str}"
    desc = {
      'name' => name,
      'description' => "description-" + str,
      'author' => "author-" + str,
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
    check_env(name)
    run_kaenv('-d', name)
    envfile.unlink
  end
end
