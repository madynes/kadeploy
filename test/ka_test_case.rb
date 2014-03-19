KADEPLOY_LIBS=ENV['KADEPLOY3_LIBS']||File.join(File.dirname(__FILE__), '..','lib')
KADEPLOY_SERVER=ENV['KADEPLOY3_SERVER']||'kadeploy.testbed.lan'
KADEPLOY_PORT=(ENV['KADEPLOY3_PORT']||25300).to_i
KADEPLOY_SECURE=ENV['KADEPLOY3_SECURE']||true
KADEPLOY_AUTH_HEADER=ENV['KADEPLOY3_AUTH_HEADER']||'X-Kadeploy-'
USER=ENV['USER']

$:.unshift KADEPLOY_LIBS
require 'kadeploy3/common/execute'
require 'yaml'
require 'test/unit'
require 'rubygems'
require 'net/ssh'

module KaTestCase
  def errmsg(msg,exec,out,err)
    "\t\n#{msg}\n"
    "\t=== #{@binary}(cmd) ===\n\t#{exec.command.join(' ')}\n\t===\n"\
    "\t=== #{@binary}(stdout) ===\n\t#{out.split("\n").join("\n\t")}\n\t===\n"\
    "\t=== #{@binary}(stderr) ===\n\t#{err.split("\n").join("\n\t")}\n\t===\n"
  end

  def run_ka(binary,*options)
    exec = Kadeploy::Execute[binary,*options].run!
    if block_given?
      yield(exec)
    else
      puts "\n  #{exec.command.join(' ')}"
    end

    st,out,err = exec.wait(:checkstatus => false)

    assert(err.empty?,errmsg('stderr not empty',exec,out,err))

    assert(st.exitstatus == 0,errmsg('exit status is not 0',exec,out,err))

    out
  end

  def run_ka_nodelist(binary,*options)
    okfile = `tempfile`.strip
    kofile = `tempfile`.strip
    #nodelist = @nodes.collect{ |n| ['-m',n] }.flatten!(1)
    #options += nodelist

    options += ['-o',okfile]
    options += ['-n',kofile]

    begin
      out = run_ka(@binary,*options)

      assert(!(out =~ /Error/),"\t#{@binary}: #{out.split("\n").join("\n\t")}")

      if File.exists?(kofile)
        kos = File.read(kofile).split("\n")
        assert(kos.empty?,"NODES_KO file not empty\n\t#{out.split("\n").join("\n\t")}")
      end

      assert(File.exists?(okfile),"NODES_OK file don't exists\n\t#{out.split("\n").join("\n\t")}")
      oks = File.read(okfile).split("\n")
      assert(oks.sort == @nodes.sort,"NODES_OK file does not include every nodes\n\t#{out.split("\n").join("\n\t")}")
    ensure
      `rm #{okfile}` if File.exists?(okfile)
      `rm #{kofile}` if File.exists?(kofile)
    end

    out
  end

  def load_field(config,field_path,default=nil)
    path = field_path.split('/')
    if path.size > 1
      return load_field(config[path[0]],path[1..-1].join('/'),default)
    else
      if config.nil? or config.empty? or config[path[0]].nil?
        if default
          return default
        else
          $stderr.puts "[#{ARGV[0]}] Field missing '#{path[0]}'"
          exit 1
        end
      else
        return config[path[0]]
      end
    end
  end

  def load_config()
    if ARGV.size < 2
      puts "usage: ruby #{$0} -- <yaml_config> <nodefile> [<vlan_id>] (see --help)"
      exit 0
    end

    begin
      config = YAML.load_file(ARGV[0])
    rescue ArgumentError
      $stderr.puts "Invalid YAML file '#{configfile}'"
      exit 1
    rescue Errno::ENOENT
      $stderr.puts "File not found '#{configfile}'"
      exit 1
    end

    @binaries = {
      :kadeploy => load_field(config,'binaries/kadeploy','kadeploy3'),
      :kaenv => load_field(config,'binaries/kaenv','kaenv3'),
      :kareboot => load_field(config,'binaries/kareboot','kareboot3'),
      :kapower => load_field(config,'binaries/kapower','kapower3'),
      :kastat => load_field(config,'binaries/kastat','kastat3'),
      :kanodes => load_field(config,'binaries/kanodes','kanodes3'),
      :kaconsole => load_field(config,'binaries/kaconsole','kaconsole3'),
    }
    @envs = {
      :base => load_field(config,'environments/base'),
      :xen => load_field(config,'environments/xen'),
      :grub => load_field(config,'environments/grub'),
      :http => load_field(config,'environments/http'),
      :nfs => load_field(config,'environments/nfs'),
    }
    @deployuser = load_field(config,'deployuser')

    unless File.readable?(ARGV[1])
      $stderr.puts "Unable to read file '#{ARGV[1]}'"
      exit 1
    end

    @nodefile = ARGV[1]
    @nodes = File.read(ARGV[1]).split("\n").uniq

    @vlan = ARGV[2] if ARGV.size > 2

    @tmp = {
      :envname => '_TMP_KATESTSUITE',
      :localfile => File.join(Dir.pwd,'_TMP_KATESTSUITE'),
    }
  end

  def connect_test(node)
    hostname = ''
    begin
      Net::SSH.start(node,'root',:password => 'grid5000',:keys => "#{ENV['HOME']}/.ssh/id_rsa",:paranoid => false,:user_known_hosts_file =>'/dev/null') do |ssh|
        hostname = ssh.exec!('hostname').strip
      end
    rescue Net::SSH::HostKeyMismatch => hkm
      hkm.remember_host!
      retry
    rescue Net::SSH::AuthenticationFailed,SocketError,Errno::ECONNRESET,Errno::EHOSTUNREACH
      assert(false,'Unable to contact nodes')
    end
    assert(hostname == node,'Hostname not set correctly')
  end

  def env_desc(env)
    begin
      desc = run_ka(@binaries[:kaenv],'-p',env){}
    rescue MiniTest::Assertion
      begin
        desc = run_ka(@binaries[:kaenv],'-p',env,'-u',@deployuser){}
      rescue MiniTest::Assertion
        begin
          desc = run_ka(@binaries[:kaenv],'-p',env,'-u','root'){}
        rescue MiniTest::Assertion
          assert(false,"Unable to gather description of '#{env}' environment")
        end
      end
    end
    YAML.load(desc)
  end
end
