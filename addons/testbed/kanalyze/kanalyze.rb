#!/usr/bin/ruby


$cur_run = {}
$results = Array.new
$stats = Hash.new
$pids=[]
$csvfiles = Array.new
$microsteps=true

Signal.trap("INT") do
  puts "\nSIGINT, killing #{$0}"
  system(
    "#{CONLOG_SCRIPT} stop #{$cur_run[:run_id]} #{$cur_run[:nodefile]} #{$cur_run[:envcondir]}"
  ) if $cur_run and !$cur_run.empty?
  system("oardel #{$jobid}") 
  exit!(1)
end

require 'yaml'
require 'tempfile'
require 'fileutils'
require 'optparse'
require 'csv'
require 'shellwords'

# Config
SSH_KEY='~/.ssh/id_rsa.pub'
KAREMOTE_SCRIPT='PATH_TO_SCRIPT'
KADEPLOY_BIN=ENV['KADEPLOY_BIN']||'kadeploy3'
KADEPLOY_RETRIES=3
KABOOTSTRAP_RETRIES=3
KABOOTSTRAP_BIN=ENV['KABOOTSTRAP_BIN']||'../kabootstrap'
KABOOTSTRAP_KERNELS=ENV['KABOOTSTRAP_KERNELS']||'/home/lsarzyniec/kernels'
KABOOTSTRAP_ENVS=ENV['KABOOTSTRAP_ENVS']||'/home/lsarzyniec/envs-tmp'
ENVIRONMENT=ENV['KADEPLOY_ENV']||'wheezy-x64-base'
KASTAT_BIN='kastat3'
REMOTE=false
CONSOLE_BIN="/usr/local/conman/bin/conman"
CONSOLE_CMD="#{CONSOLE_BIN} -f -d conman"
SCRIPT_BIN="/usr/bin/script"
OARTAG="kanalyze"
GIT_REPO=ENV['GIT_REPO']||'https://gforge.inria.fr/git/kadeploy3/kadeploy3.git'
GERRIT_REPO=ENV['GERRIT_REPO']||'http://gerrit.nancy.grid5000.fr:8080/gerrit/kadeploy3'
# Kadeploy environment variables
KADEPLOY_ENV_VARS=[
  'KADEPLOY_BIN',
  'KABOOTSTRAP_BIN',
  'ENVIRONMENT',
  'KABOOTSTRAP_KERNELS',
  'KABOOTSTRAP_ENVS',
  'KABOOTSTRAP_OPTS',
  'GIT_REPO',
  'GERRIT_REPO',
  'HTTP_PROXY',
  'SSH_OPTIONS',
  'DEBUG',
]
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

module Kanalyzemode
  RESERVE=0
  INSTALL=1
  TEST=2
end


#Contains useful functions to work with g5k tools
module CommonG5K

  def cmd(cmd,checkstatus=true)
    puts "=== COMMAND: #{cmd} ===" if $verbose
    ret=`#{cmd}`
    if checkstatus and !$?.success?
      $stderr.puts("Unable to perform the command: #{cmd}\n=== Error ===\n#{ret}")
    end
    puts "=== STDOUT ===\n#{ret}" if ret and !ret.empty? and $verbose
    ret.strip
  end

  def reserve_nodes(cluster,nodes,walltime)
    puts "Make the reservation" if $verbose
    vars = ''
    KADEPLOY_ENV_VARS.each do |var|
      vars << " #{var}=\"#{ENV[var]}\"" if ENV[var]
    end
    env = (vars.empty? ? '' : "export #{vars};")
    command="oarsub -t deploy -n #{OARTAG}"
    command+=" -l {\"type='kavlan-local'\"}/vlan=1+"
    command+="{'cluster=\"#{cluster}\"'}" if cluster!=""
    command+="/nodes=#{$best ? "BEST" : nodes},walltime=#{walltime} 'ruby kanalyze.rb --installmode -y #{$expfile}"
    command+=" --kastat" if $kastat
    command+=" -v'"
    
    ret=cmd(command)
    $jobid=ret.split("\n").grep(/OAR_JOB_ID/).to_s.split("=")[1]
  end

  def prepare_env
    puts 'Enable VLAN DHCP' if $verbose
    cmd('kavlan -e')
    vlan=`kavlan -V`.chomp
    puts 'Running Kadeploy...' if $verbose
    kadeploy($nodes,ENVIRONMENT,vlan)
    puts 'done' if $verbose
  end

def kadeploy(nodes,env,vlan)
  bin=KADEPLOY_BIN
  begin
    tmpfile=cmd('mktemp')
    tmpkofile=cmd('mktemp')
    i=0
    node_list = String.new
    nodes.each { |node|
      node_list += " -m #{node}"
    }
    begin
      command="#{bin} #{node_list} -e #{env} -k -o #{tmpfile} -n #{tmpkofile}"
      command+=" --vlan #{vlan}" if vlan
      command+=" --ignore-nodes-deploying "
      cmd(command)
      deployed_nodes=File.read(tmpfile).split("\n").uniq
      i+=1
      puts deployed_nodes.sort
      puts $nodes.sort
      if File.exist?(tmpkofile)
        nodes=IO.read(tmpkofile).split("\n").uniq
        nodes.each { |node|
          node_list += " -m #{node}"
        }
      end
    end while nodes.size>0 and i<KADEPLOY_RETRIES
  ensure
    cmd("rm -f #{tmpfile}") if tmpfile
    cmd("rm -f #{tmpkofile}") if tmpkofile
  end
end

def kadeploy(nodes,env,vlan,retries=KADEPLOY_RETRIES)
  return if retries == 0
  bin=KADEPLOY_BIN
  oktmpfile=cmd('mktemp')
  kotmpfile=cmd('mktemp')
  node_list = String.new
  nodes.each { |node|
    node_list += " -m #{node.chomp}"
  }
  command="#{bin} #{node_list} -e #{env} -k -o #{oktmpfile} -n #{kotmpfile}"
  command+=" --vlan #{vlan}" if vlan
  command+=" --ignore-nodes-deploying " 
  cmd(command)
  if File.size?(kotmpfile)
    no_deployed_nodes=File.read(kotmpfile).split("\n")
    kadeploy(no_deployed_nodes,env,vlan,retries-1) if no_deployed_nodes.size > 0
    cmd("rm -f #{kotmpfile}")
  end
  cmd("rm -f #{oktmpfile}") if File.exist?(oktmpfile)
  cmd("rm -f #{kotmpfile}") if File.exist?(kotmpfile)
end

def kabootstrap(nodefile,repo_kind,commit,version)
    frontend=nil
    ret=nil
    i = 0
    begin
      ret=cmd("#{KABOOTSTRAP_BIN} #{KABOOTSTRAP_KERNELS} #{KABOOTSTRAP_ENVS} -f #{nodefile} --#{repo_kind} #{commit} -v #{version}" ,false)
      if ret.split("\n")[-1] =~ /^Frontend:\s*([\w\-_\.]+@[\w\-_\.]+)\s*$/
        frontend=Regexp.last_match(1)
      end
      i+=1
    end while frontend.nil? and i<KABOOTSTRAP_RETRIES
    
    if frontend.nil?
      exit_error("Unable to perform kabootstrap\n=== Error ===\n#{ret}")
    end
  frontend
  end

end
def kill_recursive(pid)
  begin
    # SIGSTOPs the process to avoid it creating new children
    Process.kill('STOP',pid)
    # Gather the list of children before killing the parent in order to
    # be able to kill children that will be re-attached to init
    children = `ps --ppid #{pid} -o pid=`.split("\n").collect!{|p| p.strip.to_i}
    # Directly kill the process not to generate <defunct> children
    Process.kill('KILL',pid)
    children.each do |cpid|
      kill_recursive(cpid)
    end
  rescue Errno::ESRCH
  end
end

def conlogger_start(envcondir,nodes)
  pids=[]
  puts "      Initialize monitors" if $verbose
  nodes.each do |node|
    puts "        init #{node}" if $verbose
    cmd="#{SCRIPT_BIN} -f -c '#{CONSOLE_CMD} #{node.split(".")[0]}' "
    cmd+="-t 2>#{File.join(envcondir,node+".timing")} "
    cmd+="-a #{File.join(envcondir,node+".typescript")} "
    cmd+="1>/dev/null"
    cmd+="&"
    system(cmd)
  end
  puts "      Start monitoring" if $verbose
end

def conlogger_stop(envcondir,nodes)
  puts "      Kill monitors" if $verbose
  nodes.each do |node|
    # Get the list of processus for the current user
    psresult=`ps -u $USER -o pid= -o command=`.split("\n")
    # Only select the monitoring processus on the selected node
    commands=psresult.select { |line| (line =~ /#{SCRIPT_BIN}/ && line=~/#{CONSOLE_BIN}/ && line =~/#{node}/) }
    if(!commands.empty?)
     # Get the pid of the command
      pid=commands[0].split(" ")[0]
      puts "        killing #{node} monitoring" if $verbose
      kill_recursive(pid.to_i)
    end
  end
  puts "      Stop monitoring" if $verbose
end

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
  versions=Array.new
  git=Array.new
  deployments=0
  exps.each do |exp|
    check_field('name',exp['name'])
    check_field('times',exp['times'],Fixnum)
    if exp['simult']
      check_field('simult',exp['simult'],Array)
      exp['simult'].each_index do |i|
        check_field("simult/#{i}",exp['simult'][i],Fixnum)
      end
      exp.delete('simult') if exp['simult'].empty?
    end
    if exp['times'] <= 0
      yaml_error("'times' field should be > 0")
    end
    deployments+=exp['times']
    if exp['git']
      git.push(exp['git'])
    end
    if exp['version']
      versions.push(exp['version'])
    end
    check_field('environments',exp['environments'])
    exp['environments'].each do |env|
      check_env(env) if $mode==Kanalyzemode::TEST
    end
    exp['macrosteps'] = {} if exp['macrosteps'].nil?

    exp['macrosteps']['SetDeploymentEnv'] = {} if exp['macrosteps']['SetDeploymentEnv'].nil?
    check_macro(:SetDeploymentEnv,exp['macrosteps']['SetDeploymentEnv'])

    exp['macrosteps']['BroadcastEnv'] = {} if exp['macrosteps']['BroadcastEnv'].nil?
    check_macro(:BroadcastEnv,exp['macrosteps']['BroadcastEnv'])

    exp['macrosteps']['BootNewEnv'] = {} if exp['macrosteps']['BootNewEnv'].nil?
    check_macro(:BootNewEnv,exp['macrosteps']['BootNewEnv'])
  end
  $walltime=deployments/6+1 if $walltime==0
  puts "versions: #{versions.join(" ")}" if $verbose
  puts "git: #{git.join(" ")}" if $verbose
  $kastat=true if (git.uniq.count>1 && versions.uniq.count>1)
  puts "Kastat Method: #{$kastat}" if $verbose
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

def add_result(kind, env , result, time, ok, ko)
  h = Hash.new
  h["kadeploy"] = {}
  h["kadeploy"]["version"] = `#{$kadeploy} -v`.split(" ")[3]
  h["kadeploy"]["git_revision"] = `git describe --tags 2>/dev/null|| echo "error"`.split(" ")[0]
  h["kadeploy"]["git_revision_date"] = `git show 2>/dev/null|| echo " \n \n :error"`.split("\n")[2].split(":   ")[1] 
  h["kind"] = kind
  h["env"] = env
  h["testname"] = $name
  h["time"] = time
  h["status"] = result
  h["nodes"] = {}
  h["nodes"]["list"] = $nodes.clone
  h["nodes"]["ok"] = ok.to_i
  h["nodes"]["ko"] = ko.to_i
  $results.push(h)
end

def store_results(resfile)
  outFile = File.new(resfile, "w+")
  outFile.puts($results.to_yaml)
  outFile.close
end

def store_stats(expname,expdir, iterCount)
  statfile=File.new(File.join($statsdir,expname+".yml"),"w")
  statfile.write($stats.to_yaml)
  statfile.close
  if($stats.size>0)
    csvfile=CSV.open(File.join($statsdir,expname+".csv"),"w") do |csv|
      csv<<$stats.first[1].keys.sort 
      $stats.each do |key,stat|
        keytab=stat.keys.sort
        stattab=[]
        keytab.each do |k|
          stattab.push(stat[k])
        end
        csv<<stattab
      end
    end
    $csvfiles.push(File.join(expname+".csv"))
  end
end


def count_lines(filename)
  count = `(wc -l #{filename} 2>/dev/null || echo 0) | cut -f 1 -d" "`
  return count.to_i
end

def gen_logs_dir(workdir,env,simult)
  if simult
    workdir = File.join(workdir,"simult-#{simult}")#workdir is a folder like simult-n/simult-n:i with i<n
  end

  envlogdir = File.join(workdir,"logs")
  puts "      Creating logs dir '#{envlogdir}'" if $verbose
  FileUtils.mkdir_p(envlogdir)

  if simult
    envresultfile=File.join(workdir,'..','..','..','results')
  else
    envresultfile = File.join(workdir,'..','..','results')
  end

  envdebugfile = File.join(envlogdir,'debug')
  envworkflowfile = File.join(envlogdir,'workflow_id')
  envdatefile = File.join(envlogdir,'time')

  envcondir = File.join(workdir,"consoles")
  puts "      Creating consoles dir '#{envcondir}'" if $verbose
  FileUtils.mkdir_p(envcondir)
  envconbugdir = File.join(envcondir,'bugs')
  puts "      Creating consoles bugs dir '#{envconbugdir}'" if $verbose
  FileUtils.mkdir_p(envconbugdir)


  sleep 1

  system("date > #{envdatefile}")

  return envcondir,envresultfile,envdebugfile,envconbugdir
 
end

def link_bugs(envcondir,envresultfile, envdebugfile,envconbugdir)
  puts '      Linking bugs' if $verbose
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
          end
        end
      end
    end
  end

end

def kastat_method(expname,env,kadeploy_version,iter,nok,nko,wid_file)
    $microsteps=false
    h={}
    h["expname"]=expname
    h["env"]=env
    h["kadeploy"]=kadeploy_version
    h["iter"]=iter
    h["id"]=expname+"-"+iter.to_s+"-"+env
    h["success"]=nok*100/(nok+nko)

    workflow_id=IO.read(wid_file.path)
    
    str=`#{KASTAT_BIN} -d -m #{$nodes[0]} -f step1 -f step2 -f step3 -f step1_duration -f step2_duration -f step3_duration -w #{workflow_id}`
    str=str.split("\n").last

    res_tab=str.split(",")

    h["step1"]=res_tab[0]
    h["step2"]=res_tab[1]
    h["step3"]=res_tab[2]
    h["time1"]=res_tab[3]
    h["time2"]=res_tab[4]
    h["time3"]=res_tab[5]
    return h
end

def add_stats(expname,envdebugfile,env,run_id,iter,nok,nko,wid_file)

  hashes={}
  branch="0"#branch (nodeset) of the current line
  kadeploy_version=`#{$kadeploy} -v`.split(" ").last

# Uses the Kastat method: works on versions of Kadeploy lower than 3.1.6 but doesn't support microsteps and nodeset splits
  
  if $kastat 
    hashes["0"]={}
    hashes["0"].update(kastat_method(expname,env,kadeploy_version,iter,nok,nko,wid_file))
  else
    trunk="0"#origin of a nodeset split
    microstep_order={}
    step_order={}

#  Opens the debug file and parses it
    case 
    when (kadeploy_version[0..4]=="3.1.6" || kadeploy_version[0..4]=="3.1.7")  
      File.open(envdebugfile) do |file|
        file.each_line do |line|  

          if line =~ /\A\[([\w|:|.]+)\]/ ||  line =~ /\A\(([\w|:]+)\)/ 
            branch=Regexp.last_match(1)
          end

          if hashes[branch].nil?
            hashes[branch]={}
            microstep_order[branch]=0
            step_order[branch]=0
          end
      
          hashes[branch]["expname"]=expname
          hashes[branch]["env"]=env
          hashes[branch]["kadeploy"]=kadeploy_version
          hashes[branch]["iter"]=iter
          hashes[branch]["id"]=expname+"-"+iter.to_s+"-"+env+"-"+branch
          hashes[branch]["success"]=nok*100/(nok+nko)
          
          if line =~ /Nodeset \[([\w|:]+)\] split into :/
            trunk=Regexp.last_match(1)
            while !((line=file.gets) =~ /---/)
              if line=~ /\A\[([\w|:]+)\]   \[([\w|:]+)\]/ || line=~ /\A  \[([\w|:]+)\]/
                hashes[Regexp.last_match(1)]={}
                hashes[Regexp.last_match(1)].update(hashes[trunk])
                microstep_order[Regexp.last_match(1)]=microstep_order[trunk]
                step_order[Regexp.last_match(1)]=step_order[trunk]
              end
            end
            hashes.delete(trunk) {puts "Error: #{trunk} key not found in stats hashes"}
          end

          if line =~ /End of step ([\w]+)\ after\ ([\d]+)s/
            microstep_order[branch]=0
            step=Regexp.last_match(1)
            time=Regexp.last_match(2)
            if step =~ /SetDeploymentEnv/
              hashes[branch]["step1"]=step
              hashes[branch]["time1"]=time
              step_order[branch]=1
            end
            if step =~ /BroadcastEnv/
              hashes[branch]["step2"]=step
              hashes[branch]["time2"]=time
              step_order[branch]=2
            end
            if step =~ /BootNewEnv/
              hashes[branch]["step3"]=step
              hashes[branch]["time3"]=time
              step_order[branch]=3
            end
          end

          if line =~ /~ Time in ([\w]+): ([\d]+)s/
            current_step=(step_order[branch].to_i+1).to_s
            microstep=Regexp.last_match(1)
            time=Regexp.last_match(2)
            if(hashes[branch].has_value?("step"+current_step+":"+microstep))
              microstep_order[branch]=hashes[branch].key("step"+current_step+":"+microstep).split("_").to_i
            else
              microstep_order[branch]=microstep_order[branch].to_i+1
            end
            hashes[branch]["time"+current_step+"_"+microstep_order[branch].to_s]=time
            hashes[branch]["step"+current_step+"_"+microstep_order[branch].to_s]="step"+current_step+":"+microstep
          end

      end#end each line
    file.close
    end#end file.open
    else#old/unknown version case => uses kastat method
      puts "Unknown or old version of Kadeploy (<=3.1.5): using Kastat method (no microsteps)" if $verbose 
      hashes["0"]={}
      hashes["0"].update(kastat_method(expname,env,kadeploy_version,iter,nok,nko,wid_file))
    end #end case
  end#end if $kastat
  hashes.each do |key,h|
    if(h["step1"] && h["step2"] && h["step3"])
      h["branch"]=key
      $stats.store(run_id+"-"+expname+"-"+key,h)
    end
    if h["success"]==0

    end
  end
end

def _test_deploy(expname,nodes, macrosteps , env , widf , simultid , workdir , run_id, iter)
  $stderr.puts("\n### Launch[#{$name}/#{env}#{(simultid ? "(#{simultid})" : '')}]") if $verbose
  ok_file = Tempfile.new("blackboxtests-ok")
  ok = ok_file.path
  ko_file = Tempfile.new("blackboxtests-ko")
  ko = ko_file.path

  node_list = String.new
  nodes.each { |node|
    node_list += " -m #{node}"
  }
  automata_opt=''
  if macrosteps[0] and macrosteps[1] and macrosteps[2]
    automata_opt = "--force-steps \""\
      "SetDeploymentEnv|#{macrosteps[0]}&"\
      "BroadcastEnv|#{macrosteps[1]}&"\
      "BootNewEnv|#{macrosteps[2]}"\
    "\""
  end

  wid_file = nil
  wid_file = Tempfile.new("widfile")

  envcondir , envresultfile , envdebugfile  , envconbugdir = gen_logs_dir(workdir, env, simultid)

  cmd = "#{$kadeploy} #{node_list} -e \"#{env}\" -o #{ok} -n #{ko}"
  cmd += " #{automata_opt}" if automata_opt and !automata_opt.empty?
  cmd += " -k #{$key} " if $key
  cmd += " --write-workflow-id #{wid_file.path}"

  cmd += " | sed 's/.*/(#{simultid}) &/'" if simultid
  cmd += " 1> #{envdebugfile} 2> #{envdebugfile}"
 
  nodefile=Tempfile.new('nodefile')
  nodes.each{ |node| nodefile.write(node+'\n') }
  
  $cur_run[:run_id] = run_id
  $cur_run[:envcondir] = envcondir

  puts "      Init conman monitoring #{(simultid ? simultid : '')}" if $verbose
  pids=[]
  conlogger_start(envcondir,nodes)
  puts "        Running Kadeploy: #{cmd}"
  res=system(cmd)
  #res=system("touch "+envdebugfile) #useful to test without really deploying...
  #res=system("cp ~/debug #{envdebugfile}")

  puts "      Stop conman monitoring #{(simultid ? simultid : '')}" if $verbose
  conlogger_stop(envcondir,nodes)

  nodefile.unlink

  link_bugs(envcondir,envresultfile,envdebugfile,envconbugdir);
    unless res
    $stderr.puts 'Kadeploy command failed, exiting'
    $stderr.puts cmd
    exit!(1)
  end


  add_stats(expname,envdebugfile,env,run_id,iter,count_lines(ok),count_lines(ko),wid_file)

  wid_file.unlink

  return (count_lines(ko) == 0), count_lines(ok), count_lines(ko),envresultfile unless $check
  if (count_lines(ko) > 0) then
    IO.readlines(ko).each { |node|
      $stderr.puts "### KO[#{node.chomp}]"
    }
  CommonG5K.kadeploy($nodes,ENVIRONMENT,`kavlan -V`.chomp)    
  end
  if (count_lines(ko) == 0) then
    deployed_nodes = Array.new
    IO.readlines(ok).each { |node|
      deployed_nodes.push(node.chomp)
    }
    results = Hash.new
    deployed_nodes.each { |node|
      cmd = "ssh -q -o BatchMode=yes -o StrictHostKeyChecking=no -o PreferredAuthentications=publickey -o ConnectTimeout=2 root@#{node} \"true\" 1>&2"
      res = system(cmd)
      results[node] = res
    }
    no_errors = true
    results.each_pair { |node,res|
      if not res then
        $stderr.puts "### CantConnect[#{node}]"
        no_errors = false
      end
    }
    return no_errors, count_lines(ok), count_lines(ko),envresultfile
  else
    return false, count_lines(ok), count_lines(ko),envresultfile
  end
end

def test_dummy(expname,macrosteps , env , widf , workdir , run_id, iter)
  start = Time.now.to_i
     res, nok, nko, envresultfile = _test_deploy(expname,$nodes,macrosteps, env , widf ,nil , workdir , run_id,iter)
  time = Time.now.to_i - start
  if res then
    add_result("seq", env , "ok", time, nok, nko)
  else
    add_result("seq", env , "ko", time, nok, nko)
  end
  store_results(envresultfile)
end

def test_simultaneous_deployments(expname,macrosteps, env , simult , widf , workdir , run_id,iter)
  start = Time.now.to_i
  nodes_hash = Hash.new
  (0...simult).to_a.each { |n|
    nodes_hash[n] = Array.new
  }
  $nodes.each_index { |i|
    nodes_hash[i.modulo(simult)].push($nodes[i])
  }
  tid_array = Array.new
  tid_hash_result = Hash.new
  envresultfile=String.new
  (0...simult).to_a.each { |n|
    tid = Thread.new {
      r, o, k ,envresultfile = _test_deploy(expname,nodes_hash[n], macrosteps, env, widf, "#{simult}:#{n}" , workdir , run_id, iter)
      tid_hash_result[tid] = [r, o, k]
    }
    tid_array << tid
  }
  result = true
  nodes_ok = 0
  nodes_ko = 0
  tid_array.each { |tid|
    tid.join
    nodes_ok += tid_hash_result[tid][1].to_i
    nodes_ko += tid_hash_result[tid][2].to_i
    if not tid_hash_result[tid][0] then
      result = false
    end
  }
  time = Time.now.to_i - start
  if result then
    add_result("simult-#{simult}", env, "ok", time, nodes_ok, nodes_ko)
  else
    add_result("simult-#{simult}", env, "ko", time, nodes_ok, nodes_ko)
  end
  store_results(envresultfile)
end

def test_env(workdir,expname,run_id,macrosteps,env,iter,simult=nil)

    puts "    Testing environment '#{env}'#{(simult ? " simult \##{simult}" : '')}" if $verbose
    if(!simult)
      test_dummy(expname,macrosteps,env,nil,workdir,run_id,iter)
    else
      test_simultaneous_deployments(expname,macrosteps,env,simult,nil,workdir,run_id,iter)
    end

end

def check_args(name,yaml_file,nodes,keyfile,kadeploy,nodescount,exp)

  $exps=Array.new
  $current_exp=""
  $nodes=Array.new
  $key=String.new
  $name=String.new

#checks the name
  date=(Time.now.year.to_s+"-"+Time.now.mon.to_s+"-"+Time.now.day.to_s)+"-"
  $name=(name!="" ? name+"-" : "")+date+Time.now.to_s.split(" ")[3].split(":").join("-")


#checks the yaml file
    if yaml_file.empty?
      exit_error "You have to specify a YAML test file"
    end
    if !File.exist?(yaml_file)
      exit_error "The file #{yaml_file} does not exist"
    end
    yaml_file = File.expand_path(yaml_file)
    begin
      $exps = YAML.load_file(yaml_file)
    rescue
      exit_error("file '#{yaml_file}' should use YAML format")
    end
    check_exp($exps)

#checks the exp name
  if $mode==Kanalyzemode::TEST
    if $exps[exp]
      $current_exp=$exps[exp]
    else
      exit_error("The experiment #{exp} is not in the YAML file")
    end
  end

#ckecks the time
  if ($walltime<0)
    exit_error "Reservation duration must be a positive integer"
  end

#checks the nodes file
   if $mode!=Kanalyzemode::RESERVE 
    if $filenode.empty? && nodes.empty?
      $stderr.puts "No nodes specified. Using $OAR_FILE_NODES"
      $filenode=`echo $OAR_FILE_NODES`.chomp
    end
    if !File.exists?($filenode)
      if($filenode==`echo $OAR_FILE_NODES`.chomp)
        exit_error "You have to reserve some nodes to run "+$scriptname
      else
        exit_error "The file #{$filenode} does not exist"
      end
    else
      File.read($filenode).split("\n").uniq.each { |node| nodes.push(node) }
    end
    $nodes=(nodes.uniq)
  end
#checks the key file
  if !File.exist?(File.expand_path(keyfile))
    $stderr.puts "The file #{keyfile} does not exist. Using "+SSH_KEY
    keyfile=SSH_KEY
  end
  $key = File.expand_path(keyfile)

#checks kadeploy command
  kadeploy_version=`#{kadeploy} -v`.split(" ").last[0..4]
  case
  when kadeploy_version=="3.1.5"
    kadeploy_options='-V 4 -d'
  when (kadeploy_version=="3.1.6" || kadeploy_version=="3.1.7")
    kadeploy_options='-V 5 -d'
  end
  $kadeploy="#{kadeploy} #{kadeploy_options}" 
  if $mode==Kanalyzemode::RESERVE
#checks nodes count
    if (!$best && nodescount<2) 
      exit_error "You have to test with at least 2 nodes"
    end
    $nodescount=nodescount
  end
end

def load_cmdline_options
  nodes = Array.new
  keyfile = SSH_KEY
  name= String.new
  exps = Array.new
  kadeploy = KADEPLOY_BIN
  progname = File::basename($PROGRAM_NAME)
  exp=0
  $best=false
  $filenode =""
  $expfile=""
  $check=false
  $verbose=false
  $kastat=false
  $dir="."
  $cluster=""
  $walltime=0
  $mode=Kanalyzemode::RESERVE
  nodescount=2

  opts = OptionParser::new do |opts|
    opts.summary_indent = "  "
    opts.summary_width = 28
    opts.program_name = progname
    opts.banner = "Usage: #{progname} -y yaml_file [options]"
    opts.separator ""
    opts.separator "General options:"
    opts.on("--kastat","Forces method Kastat for stats (doesn't handle nodeset splits nor microsteps)") { |k| $kastat=k}
    opts.on("-k", "--key FILE", "Public key to copy in the root's authorized_keys") { |f| keyfile=f }
    opts.on("-r", "--results-directory DIR", "Directory to put results ( ./ by default )"){ |d| $dir=File.join(".",d) }
    opts.on("-v", "--verbose","Verbose mode (speaks a lot)") { |v| $verbose=v }
    opts.on("-y", "--yaml-file FILE", "YAML file containing the instructions for the test") { |f| $expfile=f }
    opts.on("-C", "--check", "Checks the nodes connecting to them with SSH (not enabled by default)") { |c| $check=c }
    opts.on("-N", "--name NAME", "Name of the test run") { |n| name=n }
    opts.separator "Reserve mode options: #{$0} -y EXPFILE [--reservemode][options]"
    opts.on("--reservemode","Launches Kanalyze in reserve mode (enabled by default)") {|l| $mode=Kanalyzemode::RESERVE}
    opts.on("--best","Uses the most possible nodes") {|b| $best=true}
    opts.on("-c", "--cluster CLUSTER", "Selects the cluster to test") { |c| $cluster=c }
    opts.on("-n", "--nodescount NODESCOUNT", "Number of nodes used for the test (min. 2)") { |n| nodescount=n }
    opts.on("-w", "--walltime TIME", "Reservation duration") { |w| $walltime=w.to_i}
    opts.separator "Install mode options: #{$0} --installmode -y EXPFILE [options]"
    opts.on("--installmode","Launches Kanalyze in install mode (reservation must be done)") {|l| $mode=Kanalyzemode::INSTALL}
    opts.on("-f", "--file MACHINELIST", "Files containing list of nodes")  { |f| $filenode=f }
    opts.separator "Test mode options: #{$0} --testmode -y EXPFILE [options]"
    opts.on("--testmode","Launches Kanalyze in test mode (reservation and frontend installation must be done)") {|l| $mode=Kanalyzemode::TEST}
    opts.on("-e", "--experiment EXP","Number of the experiment to run") {|e| exp=e}
  end

  opts.parse!(ARGV)
  check_args(name,$expfile,nodes,keyfile,kadeploy,nodescount.to_i,exp.to_i)
end

def run_test(exp)
  $results=Array.new
  puts "Running experiment '#{exp['name']}'" if $verbose
  expdir = File.join($savedir,exp['name'])
  puts "  Creating experiments directory '#{expdir}'" if $verbose
  FileUtils.mkdir_p(expdir)
  
  puts "  Start to iterate" if $verbose

  exp['times'].times do |i|
    puts "  Iteration ##{i}" if $verbose
    testname = "test-#{i}"
    testdir = File.join(expdir,testname)
    puts "    Creating #{testname} dir '#{testdir}'" if $verbose
    FileUtils.mkdir_p(testdir)

    macrosteps=Array.new(3)
    macrosteps[0]=gen_macro('SetDeploymentEnv',exp['macrosteps']['SetDeploymentEnv'])
    macrosteps[1]=gen_macro('BroadcastEnv',exp['macrosteps']['BroadcastEnv'])
    macrosteps[2]=gen_macro('BootNewEnv',exp['macrosteps']['BootNewEnv'])

    exp['environments'].each do |env|
      run_id="#{$name}-#{i}-#{env}"
      envdir = File.join(testdir,env)
      puts "    Creating environment dir '#{envdir}'" if $verbose
      FileUtils.mkdir_p(envdir)

      if exp['simult']
        exp['simult'].each do |simult|
         
          if simult > $nodes.size
            puts "    !!! Not enough nodes for simult #{simult}, ignoring"
            next
          end
          run_id += "-simult-#{simult}"
          simuldir = File.join(envdir,"simult-#{simult}")
          puts "    Creating simult-#{simult} dir '#{simuldir}'" if $verbose
          FileUtils.mkdir_p(testdir) 
          test_env(simuldir,exp['name'],run_id,macrosteps,env,i,simult)
        end
      else
        test_env(envdir,exp['name'],run_id,macrosteps,env,i)
      end
    end
  end
  store_stats(exp['name'],expdir,exp['times'])
  $stats={}
end

include CommonG5K

$scriptname=File.basename($0,File.extname($0))
load_cmdline_options
$savedir = File.join($dir,$scriptname+"-"+$name)

CommonG5K.reserve_nodes($cluster,$nodescount,$walltime) if $mode==Kanalyzemode::RESERVE

if $mode==Kanalyzemode::INSTALL
  CommonG5K.prepare_env()
  puts "Creating directory '#{$savedir}'" if $verbose
  FileUtils.mkdir_p($savedir)

  $statsdir=File.join($savedir,"stats")
  puts "Creating stats directory '#{$statsdir}'" if $verbose
  FileUtils.mkdir_p($statsdir)

  git=""
  version=""
  $exps.each do |exp|
    if ( exp['git']!=git || exp['version']!=version )
      puts "New Kadeploy version to use: performing Kabootstrap" if $verbose
      if $exps.index(exp)>0
        CommonG5K.cmd("kavlan -e")
        kadeploy($nodes,ENVIRONMENT,`kavlan -V`.chomp)#Redeploys nodes before Kabootstrap if it's not the first experience
      end
      frontend=CommonG5K.kabootstrap("$OAR_FILE_NODES","git",exp['git'],exp['version'])
    end
    git=exp['git']
    version=exp['version']
    command="scp #{$0} #{$expfile} #{frontend}:."
    CommonG5K.cmd(command)
    command="ssh #{frontend} ruby #{$0} --testmode -y #{$expfile.split('/').last} -f NODEFILE -e #{$exps.index(exp)} -v"
    command+=" --kastat" if $kastat
    ret=CommonG5K.cmd(command)
    remote_savedir=/Done, statistics are available in '(.+)'/.match(ret.split("\n").last)[1]
    remote_statsdir=File.join(remote_savedir,"stats")
    remote_expdir=File.join(remote_savedir,exp['name'])
    command="scp -r #{frontend}:#{remote_statsdir} #{frontend}:#{remote_expdir} #{$savedir}"
    CommonG5K.cmd(command)
  end
end

if $mode==Kanalyzemode::TEST
  puts "Creating directory '#{$savedir}'" if $verbose
  FileUtils.mkdir_p($savedir)

  $statsdir=File.join($savedir,"stats")
  puts "Creating stats directory '#{$statsdir}'" if $verbose
  FileUtils.mkdir_p($statsdir)
  if $current_exp.nil?
    $exps.each do |exp|
      run_test(exp)
    end
  else
    run_test($current_exp) 
  end
  rscript= <<RSCRIPT
library(ggplot2)

args=commandArgs(TRUE)

if (length(args)==0) files=c("#{$csvfiles.join("\",\"")}") else files=args

data=data.frame()

for (file in files)
{  
  if(length(data)==0)
  {
    data<-read.csv(file,head=TRUE,sep=",")
  }
  else
  {
    data<-rbind(data,read.csv(file,head=TRUE,sep=","))
  }
}

numl=length(data[,1])
numc=length(data[1,])

zeros=rep(0,numl)
times_df=cbind(zeros,data$time1,data$time2,data$time3)
cumtimes_tmp=apply(times_df,1,cumsum)
cumtimes=as.vector(cumtimes_tmp)

maxis=apply(cumtimes_tmp,1,max)
minis=apply(cumtimes_tmp,1,min)
means=apply(cumtimes_tmp,1,mean)
cumtimes_stats=as.vector(cbind(maxis,minis,means))

run_ids=as.vector(apply(data["id"],1,function(x) rep(x,4)))
run_ids_stats=as.vector(sapply(c("Maximum","Minimum","Mean"),function(x) rep(x,4)))

times=as.vector(t(cbind(data["time1"],data["time2"],data["time3"])))
times1=as.vector(t(data["time1"]))
times2=as.vector(t(data["time2"]))
times3=as.vector(t(data["time3"]))

kadeploy_version=as.vector(t(data["kadeploy"]))
names1=as.vector(t(data["step1"]))
names2=as.vector(t(data["step2"]))
names3=as.vector(t(data["step3"]))

experiments=as.vector(t(data["expname"]))
success=as.vector(t(data["success"]))
run_ids_success=as.vector(t(data["id"]))
iters=as.vector(t(data["iter"]))

output=c()

success_mean=mean(success)
time1_mean=mean(times1)
time2_mean=mean(times2)
time3_mean=mean(times3)

output=c(output,paste("Success Rate \\\\dotfill",round(success_mean,2),"\\\\% \\\\\\\\"))
output=c(output,paste("Step1 duration mean \\\\dotfill",round(time1_mean,2),"s \\\\\\\\"))
output=c(output,paste("Step2 duration mean \\\\dotfill",round(time2_mean,2),"s \\\\\\\\"))
output=c(output,paste("Step3 duration mean \\\\dotfill",round(time3_mean,2),"s \\\\\\\\"))

for(level in levels(data$kadeploy))
{
  dataset=subset(data,kadeploy==level)
  output=c(output,paste("Step1 duration mean for Kadeploy",level,"\\\\dotfill",round(mean(as.vector(t(dataset["time1"]))),2),"s \\\\\\\\"))
  output=c(output,paste("Step2 duration mean for Kadeploy",level,"\\\\dotfill",round(mean(as.vector(t(dataset["time2"]))),2),"s \\\\\\\\"))
  output=c(output,paste("Step3 duration mean for Kadeploy",level,"\\\\dotfill",round(mean(as.vector(t(dataset["time3"]))),2),"s \\\\\\\\"))
}

times1_by_macro=subset(data,select=c("step1","time1"))
times2_by_macro=subset(data,select=c("step2","time2"))
times3_by_macro=subset(data,select=c("step3","time3"))
for(level in levels(data$step1))
{
  time1_by_macro_mean=mean(t(subset(times1_by_macro,step1==level)["time1"]))
  output=c(output,paste(level,"duration mean \\\\dotfill",round(time1_by_macro_mean,2),"s \\\\\\\\"))
}
for(level in levels(data$step2))
{
  time2_by_macro_mean=mean(t(subset(times2_by_macro,step2==level)["time2"]))
  output=c(output,paste(level,"duration mean \\\\dotfill",round(time2_by_macro_mean,2),"s \\\\\\\\"))
}
for(level in levels(data$step3))
{
  time3_by_macro_mean=mean(t(subset(times3_by_macro,step3==level)["time3"]))
  output=c(output,paste(level,"duration mean \\\\dotfill",round(time3_by_macro_mean,2),"s \\\\\\\\"))
}

dir.create("pictures")

steps=c("0","step1","step2","step3")
fr=data.frame(cumtimes_stats,steps,run_ids_stats)

graph<-ggplot(fr,aes(x=steps,y=cumtimes_stats,color=run_ids_stats,group=run_ids_stats))+geom_point()+geom_line()#+theme(legend.position="bottom") 
graph<-graph+ylab("Time (s)")+xlab("Steps")+ggtitle("Evolution of steps on the time")+scale_fill_discrete(name="Runs")
ggsave(file=paste("pictures/steps-line.jpeg",sep=""),dpi=300)

steps=c("step1","step2","step3")
fr=data.frame(times,steps)

graph<-ggplot(fr,aes(x=steps,y=times,fill=steps,group=steps))+geom_boxplot(alpha=.5)+geom_line()+theme(legend.position="bottom")
graph<-graph+ylab("Time (s)")+xlab("Steps")+ggtitle("Times of steps")+scale_fill_discrete(name="Steps")
ggsave(file=paste("pictures/steps-boxplot.jpeg",sep=""),dpi=300)

groups=paste(kadeploy_version,names1)
fr=data.frame(times1,groups,kadeploy_version)

graph<-ggplot(fr,aes(x=groups,y=times1,fill=kadeploy_version,group=groups))+geom_boxplot(alpha=.5)+geom_line()
graph=graph+scale_fill_discrete(name="Kadeploy Versions")
graph<-graph+ylab("Time (s)")+xlab("Versions")+ggtitle(paste("Times of step 1 for different versions of Kadeploy"))
graph<-graph+theme(axis.text.x = element_text(angle = 90))
ggsave(file=paste("pictures/boxplot1-per-kadeploy.jpeg",sep=""),dpi=300)

groups=paste(kadeploy_version,names2)
fr=data.frame(times2,groups,kadeploy_version)

graph<-ggplot(fr,aes(x=groups,y=times2,fill=kadeploy_version,group=groups))+geom_boxplot(alpha=.5)+geom_line()
graph=graph+scale_fill_discrete(name="Kadeploy Versions")
graph<-graph+ylab("Time (s)")+xlab("Versions")+ggtitle(paste("Times of step 2 for different versions of Kadeploy"))
graph<-graph+theme(axis.text.x = element_text(angle = 90))
ggsave(file=paste("pictures/boxplot2-per-kadeploy.jpeg",sep=""),dpi=300)

groups=paste(kadeploy_version,names3)
fr=data.frame(times3,groups,kadeploy_version)

graph<-ggplot(fr,aes(x=groups,y=times3,fill=kadeploy_version,group=groups))+geom_boxplot(alpha=.5)+geom_line()
graph=graph+scale_fill_discrete(name="Kadeploy Versions")
graph<-graph+ylab("Time (s)")+xlab("Versions")+ggtitle(paste("Times of step 3 for different versions of Kadeploy"))
graph<-graph+theme(axis.text.x = element_text(angle = 90))
ggsave(file=paste("pictures/boxplot3-per-kadeploy.jpeg",sep=""),dpi=300)

groups=paste(experiments,iters)
fr=data.frame(groups,success,experiments)

graph<-ggplot(fr,aes(x=groups,y=success,fill=experiments))+geom_bar(stat="identity",alpha=.5)
graph=graph+scale_fill_discrete(name="Experiments")
graph<-graph+ylab("Success Rate (%)")+xlab("Runs")+ggtitle(paste("Success rate of different test runs"))
graph<-graph+theme(axis.text.x = element_text(angle = 90))
ggsave(file=paste("pictures/success.jpeg",sep=""),dpi=300)
RSCRIPT

rscript_micro= <<RSCRIPT_M
#MICROSTEPS

microtimes1_cols=c()
microtimes2_cols=c()
microtimes3_cols=c()
microids1=c()
microids2=c()
microids3=c()

for(col in colnames(data))
{
  if(substr(col,1,6)=="time1_")
  {
    microtimes1_cols<-c(microtimes1_cols,col)
  }
  if(substr(col,1,6)=="time2_")
  {
    microtimes2_cols<-c(microtimes2_cols,col)
  }
  if(substr(col,1,6)=="time3_")
  {
    microtimes3_cols<-c(microtimes3_cols,col)
  }
  if(substr(col,1,6)=="step1_")
  {
    microids1<-c(microids1,col)
  }
  if(substr(col,1,6)=="step2_")
  {
    microids2<-c(microids2,col)
  }
  if(substr(col,1,6)=="step3_")
  {
    microids3<-c(microids3,col)
  }

}
microtimes1_df<-subset(data,select=microtimes1_cols)
microtimes2_df<-subset(data,select=microtimes2_cols)
microtimes3_df<-subset(data,select=microtimes3_cols)


microtimes_df=cbind(microtimes1_df,microtimes2_df,microtimes3_df)
microids=c(microids1,microids2,microids3)
cumicrotimes=as.vector(apply(microtimes_df,1,cumsum))
microrun_ids=as.vector(apply(data["id"],1,function(x) rep(x,length(microtimes_df))))

microtimes1=as.vector(t(microtimes1_df))
microtimes2=as.vector(t(microtimes2_df))
microtimes3=as.vector(t(microtimes3_df))

micronames_out=c()

micronames=unique(subset(data,select=microids))

for(i in 1:length(micronames))
{
    micronames_out=c(micronames_out,paste(colnames(micronames)[i],"\\\\dotfill",micronames[,i],"\\\\\\\\"))
}

con <- file("micronames.txt", open = "w")
writeLines(micronames_out, con = con)
close(con)



fr=data.frame(cumicrotimes,microids,microrun_ids)

graph<-ggplot(fr,aes(x=microids,y=cumicrotimes,color=microrun_ids,group=microrun_ids))+geom_point()+geom_line() 
graph<-graph+xlab("Microsteps")+ylab("Time (s)")+ggtitle("Evolution of microsteps on the time")+scale_fill_discrete(name="Runs")
graph<-graph+theme(axis.text.x = element_text(angle = 90))
ggsave(file=paste("pictures/microsteps-line.jpeg",sep=""),dpi=300)

fr=data.frame(microtimes1,microids1)

graph<-ggplot(fr,aes(x=microids1,y=microtimes1,fill=microids1,group=microids1))+geom_boxplot(alpha=.5)+geom_line()
graph<-graph+ylab("Time (s)")+xlab("Microsteps")+ggtitle(paste("Times of microsteps of ",levels(data$step1)))
graph<-graph+scale_fill_discrete(name="Microsteps")
ggsave(file=paste("pictures/microsteps1-boxplot.jpeg",sep=""),dpi=300)

fr=data.frame(microtimes2,microids2)

graph<-ggplot(fr,aes(x=microids2,y=microtimes2,fill=microids2,group=microids2))+geom_boxplot(alpha=.5)+geom_line()
graph<-graph+ylab("Time (s)")+xlab("Microsteps")+ggtitle(paste("Times of microsteps of ",levels(data$step2)))
graph<-graph+scale_fill_discrete(name="Microsteps")
ggsave(file=paste("pictures/microsteps2-boxplot.jpeg",sep=""),dpi=300)

fr=data.frame(microtimes3,microids3)

graph<-ggplot(fr,aes(x=microids3,y=microtimes3,fill=microids3,group=microids3))+geom_boxplot(alpha=.5)+geom_line()
graph<-graph+ylab("Time (s)")+xlab("Microsteps")+ggtitle(paste("Times of microsteps of ",levels(data$step3)))
graph<-graph+scale_fill_discrete(name="Microsteps")
ggsave(file=paste("pictures/microsteps3-boxplot.jpeg",sep=""),dpi=300)

RSCRIPT_M

rscript_write= <<RSCRIPT_WRITE
con <- file("data.tex", open = "w")
writeLines(output, con = con)
close(con)
RSCRIPT_WRITE


filescript=File.join($statsdir,"kanalyze.r")

puts "Generating R script: '#{filescript}'" if $verbose

File::open(filescript,"w") do |f|
  f << rscript
  f << rscript_micro if $microsteps
  f << rscript_write
  end

latex=<<LATEX_SCRIPT

\\documentclass[12pt]{article}

\\usepackage[utf8]{inputenc}
\\usepackage[english]{babel}
\\usepackage[T1]{fontenc}
\\usepackage{graphicx}
\\usepackage[top=2cm, bottom=2cm, left=2cm, right=2cm]{geometry}
\\title{Kanalyze Report}
\\date{ #{Time.now.year}-#{Time.now.mon}-#{Time.now.day}-#{Time.now.hour}:#{Time.now.min}:#{Time.now.sec} }
\\begin{document}
\\maketitle
{\\LARGE General statistics}
\\newline
\\input{"data.tex"}
\\newline
{\\LARGE Deployment with macrosteps}\\\\
\\includegraphics[width=9cm]{pictures/steps-line}
\\includegraphics[width=9cm]{pictures/success}
\\includegraphics[width=9cm]{pictures/steps-boxplot}
\\includegraphics[width=9cm]{pictures/boxplot1-per-kadeploy}
\\includegraphics[width=9cm]{pictures/boxplot2-per-kadeploy}
\\includegraphics[width=9cm]{pictures/boxplot3-per-kadeploy}
LATEX_SCRIPT

micro_latex=<<MICRO_LATEX_SCRIPT
\\newpage
{\\LARGE Deployment with microsteps}\\\\
\\includegraphics[width=9cm]{pictures/microsteps-line}
\\includegraphics[width=9cm]{pictures/microsteps1-boxplot}
\\includegraphics[width=9cm]{pictures/microsteps2-boxplot}
\\includegraphics[width=9cm]{pictures/microsteps3-boxplot}


MICRO_LATEX_SCRIPT

filescript=File.join($statsdir,"kanalyze.tex")

puts "Generating LaTeX script: '#{filescript}"

File::open(filescript,"w") do |f|
  f << latex
  f << micro_latex if $microsteps
  f << "\\end{document}"
  end

make=<<MAKE
  echo 'Executing R script'
  Rscript kanalyze.r *.csv
  echo 'Compiling LaTeX report'
  pdflatex kanalyze.tex
MAKE

makefile=File.join($statsdir,"make.sh")

File::open(makefile,"w") do |f|
  f << make
  end

puts "Done, statistics are available in '#{$savedir}'"

end
