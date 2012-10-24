$:.unshift File.join(File.dirname(__FILE__), '..', 'src','lib')
require 'execute'
require 'yaml'

module KaTestCase
  def errmsg(msg,exec,out,err)
    "\n#{msg}\n"
    "=== #{@binary}(cmd) ===\n#{exec.command.join(' ')}\n===\n"\
    "=== #{@binary}(stdout) ===\n#{out}\n===\n"\
    "=== #{@binary}(stderr) ===\n#{err}\n===\n"
  end

  def run_ka(binary,*options)
    exec = Execute[binary,*options].run!
    if block_given?
      yield(exec)
    else
      puts "\n  #{exec.command.join(' ')}"
    end

    st,out,err = exec.wait

    assert(err.empty?,errmsg('stderr not empty',exec,out,err))

    assert(st.exitstatus == 0,errmsg('exit status is not 0',exec,out,err))

    out
  end

  def run_ka_nodelist(binary,*options)
    okfile = `tempfile`.strip
    kofile = `tempfile`.strip
    #nodelist = @nodes.collect{ |n| ['-m',n] }.flatten!(1)
    #options += nodelist

    options += ['-f',@nodefile]
    options += ['-o',okfile]
    options += ['-n',kofile]

    begin
      out = run_ka(@binary,*options)

      assert(!(out =~ /^ERROR:.*$/),"#{@binary}: #{out}")
      assert(!(out =~ /^.?druby:.*$/),"#{@binary}: #{out}")

      if File.exists?(kofile)
        kos = File.read(kofile).split("\n")
        assert(kos.empty?,"NODES_KO file not empty\n#{out}")
      end

      assert(File.exists?(okfile),"NODES_OK file don't exists\n#{out}")
      oks = File.read(okfile).split("\n")
      assert(oks.sort == @nodes.sort,"NODES_OK file does not include every nodes\n#{out}")
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
      puts "usage: #{$0} <yaml_config> <nodefile>"
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
      :min => load_field(config,'environments/min'),
      :big => load_field(config,'environments/big'),
      :xen => load_field(config,'environments/xen'),
      :http => load_field(config,'environments/http'),
      :nfs => load_field(config,'environments/nfs'),
      :base => load_field(config,'environments/base'),
    }
    @deployuser = load_field(config,'deployuser')

    unless File.readable?(ARGV[1])
      $stderr.puts "Unable to read file '#{ARGV[1]}'"
      exit 1
    end

    @nodefile = ARGV[1]
    @nodes = File.read(ARGV[1]).split("\n").uniq
  end
end
