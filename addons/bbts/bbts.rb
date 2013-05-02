#!/usr/bin/ruby

require 'yaml'
require 'tempfile'
require 'fileutils'

# Config
SSH_KEY='~/.ssh/id_rsa.pub'
BBT_SCRIPT=File.join(File.dirname(__FILE__),'..','..','test','blackbox_tests.rb')
CONLOG_SCRIPT=File.join(File.dirname(__FILE__),'conlogger.sh')
KAREMOTE_SCRIPT='PATH_TO_SCRIPT'

KADEPLOY_BIN='kadeploy3'
KADEPLOY_OPTIONS='-V4'

REMOTE=false
REMOTE_HOST='node-hostname'
REMOTE_USER='node-user'

# Allowed values
MACROSTEPS = {
  :SetDeploymentEnv => {
    :types => [
      'Untrusted',
      'Kexec',
      'UntrustedCustomPreInstall',
      'Prod',
      'Nfsroot',
      'Dummy',
    ],
  },
  :BroadcastEnv => {
    :types => [
      'Chain',
      'Kastafior',
      'Tree',
      'Bittorrent',
      'Dummy',
    ],
  },
  :BootNewEnv => {
    :types => [
      'Kexec',
      'PivotRoot',
      'Classical',
      'HardReboot',
      'Dummy',
    ],
  },
}

def exit_error(errmsg)
  $stderr.puts errmsg
  exit 1
end

def yaml_error(msg)
  exit_error("Error in YAML file: #{msg}")
end

def check_field(name,val,type=nil)
  yaml_error("experiment should have a field '#{name}'") if val.nil? or (type.nil? and val.empty?)
  yaml_error("the field '#{name}' should have the type #{type.name}") if type and !val.is_a?(type)
end

def check_macro(type,macro)
  if macro.is_a?(Array)
    macro.each do |m|
      check_macro(type,m)
    end
  else
    unless macro.empty?
      if macro['type'].nil?
        yaml_error("macrostep #{type.to_s}/type is empty")
      else
        check_field('type',macro['type'])
        yaml_error("macrostep #{type.to_s} should be #{MACROSTEPS[type][:types].join(' or ')}") unless MACROSTEPS[type][:types].include?(macro['type'])
      end

      if macro['timeout'].nil?
        yaml_error("macrostep #{type.to_s}/timeout is empty")
      else
        if macro['timeout'] <= 0
          yaml_error("'macrosteps/timeout' field should be > 0")
        end
      end

      if macro['retries'].nil?
        yaml_error("macrostep #{type.to_s}/retries is empty")
      else
        if macro['retries'] < 0
          yaml_error("'macrosteps/retries' field should be >= 0")
        end
      end
    end
  end
end

def check_env(env)
  unless REMOTE
    $kaenvs = `kaenv3 -l | grep -v '^Name' | grep -v '^####' | cut -d ' ' -f 1`.split("\n") unless $kaenvs
    yaml_error("env '#{env}' does not exists") unless $kaenvs.include?(env)
  end
end

def check_exp(exps)
  yaml_error("root should be a YAML Array") unless exps.is_a?(Array)
  exps.each do |exp|
    check_field('name',exp['name'])
    check_field('times',exp['times'],Fixnum)
    if exp['times'] <= 0
      yaml_error("'times' field should be > 0")
    end
    check_field('environments',exp['environments'])
    exp['environments'].each do |env|
      check_env(env)
    end
    exp['macrosteps'] = {} if exp['macrosteps'].nil?

    exp['macrosteps']['SetDeploymentEnv'] = {} if exp['macrosteps']['SetDeploymentEnv'].nil?
    check_macro(:SetDeploymentEnv,exp['macrosteps']['SetDeploymentEnv'])

    exp['macrosteps']['BroadcastEnv'] = {} if exp['macrosteps']['BroadcastEnv'].nil?
    check_macro(:BroadcastEnv,exp['macrosteps']['BroadcastEnv'])

    exp['macrosteps']['BootNewEnv'] = {} if exp['macrosteps']['BootNewEnv'].nil?
    check_macro(:BootNewEnv,exp['macrosteps']['BootNewEnv'])
  end
end

def gen_macro(type,macro)
  if macro.is_a?(Array)
    macro.collect{ |m| gen_macro(type,m) }.join(',')
  elsif macro.empty?
    ''
  else
    "#{type.to_s}#{macro['type']}:#{macro['retries']}:#{macro['timeout']}"
  end
end

def kadeploy_cmd()
  ret=nil
  if REMOTE
    ret = "#{KAREMOTE_SCRIPT} #{REMOTE_USER} #{REMOTE_HOST}"
  else
    ret = "#{KADEPLOY_BIN} #{KADEPLOY_OPTIONS}"
  end
  ret
end

if ARGV.size < 3
  exit_error("usage: #{$0} <name> <yaml_expfile> <nodefile> [<dest_dir>]")
end

if ARGV[0].empty?
  exit_error("<name> cannot be empty")
end
$name = ARGV[0]

if !ARGV[1] or !File.exists?(ARGV[1])
  exit_error("file not found '#{ARGV[1]}'")
end
begin
  $exps = YAML.load_file(ARGV[1])
rescue
  exit_error("file '#{ARGV[1]}' should use YAML format")
end
check_exp($exps)

if !ARGV[2] or !File.exists?(ARGV[2]) or ARGV[2].empty?
  $stderr.puts "file not found '#{ARGV[2]}'"
  exit 1
end
$nodefile = ARGV[2]

dir = '.'
if ARGV[3] and !ARGV[3].empty?
  FileUtils.mkdir_p(ARGV[3])
  dir = ARGV[3]
end

$scriptname=File.basename($0,File.extname($0))
$savedir = File.join(dir,"#{$scriptname}-#{$name}")

puts "Creating directory '#{$savedir}'"
FileUtils.mkdir_p($savedir)

$exps.each do |exp|
  puts "Running experiment '#{exp['name']}"
  expdir = File.join($savedir,exp['name'])
  puts "  Creating experiments directory '#{expdir}'"
  FileUtils.mkdir_p(expdir)

  logsdir = File.join(expdir,'logs')
  puts "  Creating logs dir '#{logsdir}'"
  FileUtils.mkdir_p(logsdir)

  condir = File.join(expdir,'consoles')
  puts "  Creating consoles dir '#{condir}'"
  FileUtils.mkdir_p(condir)

  puts "  Creating automata file"
  automata_name="#{$name}-#{exp['name']}"
  automata_file = Tempfile.new($scriptname)
  automata_file.write("dummy Dummy "\
    "SetDeploymentEnvDummy:0:10|"\
    "BroadcastEnvDummy:0:10|"\
    "BootNewEnvDummy:0:10\n"
  )
  automata_val = "simple #{automata_name}"
  tmp = gen_macro(:SetDeploymentEnv,exp['macrosteps']['SetDeploymentEnv'])
  automata_val += (tmp.empty? ? '' : " #{tmp}|")
  tmp = gen_macro(:BroadcastEnv,exp['macrosteps']['BroadcastEnv'])
  automata_val += (tmp.empty? ? '' : "#{tmp}|")
  tmp = gen_macro(:BootNewEnv,exp['macrosteps']['BootNewEnv'])
  automata_val += (tmp.empty? ? '' : "#{tmp}")

  automata_file.write(automata_val)

  automata_file.close

  puts "  Start to iterate"
  exp['times'].times do |i|
    puts "  Iteration ##{i}"

    testname = "test-#{i}"
    curcondir = File.join(condir,testname)

    puts "    Creating common consoles dir '#{curcondir}'"
    FileUtils.mkdir_p(curcondir)

    exp['environments'].each do |env|
      puts "    Testing environment '#{env}'"

      envtestname = "#{testname}-#{env}"
      envlogfile = File.join(logsdir,"#{envtestname}.log")
      envdebugfile = File.join(logsdir,"#{envtestname}.debug")
      envcondir = File.join(curcondir,env)
      envconbugdir = File.join(envcondir,'bugs')

      puts "      Creating consoles dir '#{envcondir}'"
      FileUtils.mkdir_p(envcondir)

      run_id="#{$name}-#{i}-#{env}"

      puts '      Init conman monitoring'
      system(
        "#{CONLOG_SCRIPT} start #{run_id} #{$nodefile} #{envcondir} &>/dev/null"
      )

      sleep 1

      puts "      Creating consoles bugs dir '#{envconbugdir}'"
      FileUtils.mkdir_p(envconbugdir)

      puts '      Running bbt'
      system(
        "#{BBT_SCRIPT} --kadeploy-cmd '#{kadeploy_cmd()}' "\
	      "-f #{$nodefile} -k #{SSH_KEY} "\
        "--env-list #{env} --max-simult 1 "\
        "-a #{automata_file.path} 1> #{envlogfile} 2> #{envdebugfile}"
      )

      puts '      Stop conman monitoring'
      system(
        "#{CONLOG_SCRIPT} stop #{run_id} #{$nodefile} #{envcondir} &>/dev/null"
      )

      puts '      Linking bugs'
      File.open(envdebugfile) do |file|
        dirls = nil
        file.each_line do |line|
          if line =~ /^\s*### KO\[(\S+)\]\s*$/ \
          or line =~ /^\s*### CantConnect\[(\S+)\]\s*$/
            nodename = Regexp.last_match(1).split('.')[0].strip
            dirls = Dir.entries(envcondir) unless dirls
            dirls.each do |filename|
              if filename =~ /^#{nodename}\..*\.gz$/
                FileUtils.ln_sf(
                  File.expand_path(File.join(envcondir,filename)),
                  envconbugdir
                )
                break
              end
            end
          end
        end
      end

    end
  end
  automata_file.unlink
end

puts "Done, statistics are available in '#{$savedir}'"
