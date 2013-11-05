require 'yaml'
require 'rubygems'
require 'net/ssh'

KADEPLOY_ENV_VARS=[
  'TESTSUITE_DIR',
  'KADEPLOY_BIN',
  'KADEPLOY_ENV',
  'KABOOTSTRAP_BIN',
  'KABOOTSTRAP_KERNELS',
  'KABOOTSTRAP_ENVS',
  'KABOOTSTRAP_OPTS',
  'GIT_REPO',
  'GERRIT_REPO',
  'HTTP_PROXY',
  'SSH_OPTIONS',
  'KANALYZE_RESULTS_DIR',
  'DEBUG',
]
TESTSUITE_DIR=ENV['TESTSUITE_DIR']||Dir.pwd
KADEPLOY_BIN=ENV['KADEPLOY_BIN']||'kadeploy3'
KADEPLOY_ENV=ENV['KADEPLOY_ENV']||'wheezy-x64-base'
KADEPLOY_RETRIES=3
KABOOTSTRAP_BIN=ENV['KABOOTSTRAP_BIN']||File.join(TESTSUITE_DIR,'kabootstrap')
KABOOTSTRAP_KERNELS=ENV['KABOOTSTRAP_KERNELS']||File.join(TESTSUITE_DIR,'kernels')
KABOOTSTRAP_ENVS=ENV['KABOOTSTRAP_ENVS']||File.join(TESTSUITE_DIR,'envs')
KABOOTSTRAP_OPTS=''
KABOOTSTRAP_RETRIES=4
GIT_REPO=ENV['GIT_REPO']||'https://gforge.inria.fr/git/kadeploy3/kadeploy3.git'
GERRIT_REPO=ENV['GERRIT_REPO']||'http://gerrit.nancy.grid5000.fr:8080/gerrit/kadeploy3'
HTTP_PROXY=ENV['HTTP_PROXY']||'http://proxy:3128'
SSH_OPTIONS=ENV['SSH_OPTIONS']||'-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=publickey -o ConnectTimeout=12 -o ConnectionAttempts=3'
SSH_KEY="#{ENV['HOME']}/.ssh/id_rsa"

TMP_DIR='/tmp/testsuite'
TEST_DIR=File.join(TMP_DIR,'test')
TEST_CONFIG='test_config.yml'
TEST_AUTH='test_auth.rb'
TEST_KADEPLOY='test_kadeploy.rb'
TEST_KAREBOOT='test_kareboot.rb'
TEST_KAPOWER='test_kapower.rb'
TEST_KAENV='test_kaenv.rb'
TEST_KASTAT='test_kastat.rb'
TEST_KANODES='test_kanodes.rb'
KANALYZE_RESULTS_DIR='kanalyze-results'
DEBUG=false

def cmd(cmd,checkstatus=true)
  puts "=== COMMAND: #{cmd} ===" if ENV['DEBUG']
  ret=`#{cmd}`
  if checkstatus and !$?.success?
    error("Unable to perform the command: #{cmd}\n=== Error ===\n#{ret}")
  end
  puts "=== STDOUT ===\n#{ret}" if ret and !ret.empty? and ENV['DEBUG']
  ret.strip
end

def scp(user,host,source,dest,reverse=false)
  if reverse
    cmd("scp -q #{SSH_OPTIONS} -r #{user}@#{host}:#{source} #{dest}")
  else
    cmd("scp -q #{SSH_OPTIONS} -r #{source} #{user}@#{host}:#{dest}")
  end
end

def ssh(user,host,cmd,checkstatus=true,password='grid5000')
  #cmd("ssh #{SSH_OPTIONS} #{host} \"#{cmd}\"")
  stdout = ""
  stderr = ""
  status = 1
  puts "=== SSH (#{host}): #{cmd} ===" if ENV['DEBUG']
  Net::SSH.start(host,user,:keys => SSH_KEY, :password=>password) do |ssh|
    ssh.open_channel do |channel|
      channel.exec(cmd) do |chan, success|
        channel.on_data do |ch, data|
          stdout += data
        end
        channel.on_extended_data do |ch, type, data|
          stderr += data
        end
        channel.on_request("exit-status") do |ch,data|
          status = data.read_long
        end
        if checkstatus and !success
          error("Unable to perform the command: '#{cmd}' on #{host}")
        end
      end
    end
  end
  puts "=== STDOUT ===\n#{stdout}" if stdout and !stdout.empty? and ENV['DEBUG']
  puts "=== STDERR ===\n#{stderr}" if stderr and !stderr.empty? and ENV['DEBUG']
  if checkstatus and status != 0
    error("Unable to perform the command: '#{cmd}' on #{host}\n=== STDOUT ===#{stdout}\n=== STDERR ===\n#{stderr}")
  end
  [ stdout, stderr, status == 0 ]
end

def error(msg)
  $stderr.puts msg
  exit 1
end

def get_vlan
  vlan=cmd('kavlan -V')
  unless $?.success?
    error('There is no VLAN in the reservation')
  end

  unless vlan.to_i > 0 and vlan.to_i <= 4
    error('The VLAN is not local')
  end

  vlan
end

def get_nodes(file)
  unless File.readable?(file)
    error("file not found '#{file}'")
  end
  File.read(file).split("\n").uniq
end

def get_repo_commit(arg)
  if arg =~ /^((?:git)|(?:gerrit)):(.*)$/
    case Regexp.last_match(1).downcase
    when 'git'
      [ GIT_REPO, Regexp.last_match(2), 'git' ]
    when 'gerrit'
      [ GERRIT_REPO, Regexp.last_match(2), 'gerrit' ]
    end
  else
    [ GIT_REPO, arg, 'git' ]
  end
end

def kadeploy(nodefile,env,vlan)
  bin=KADEPLOY_BIN
  begin
    tmpfile=cmd('mktemp')
    i=0
    begin
      cmd("#{bin} -f #{nodefile} -e #{env} -k --vlan #{vlan} -o #{tmpfile}")
      deployed_nodes=get_nodes(tmpfile)
      i+=1
    end while deployed_nodes.sort != $nodes.sort and i<KADEPLOY_RETRIES
  ensure
    cmd("rm -f #{tmpfile}") if tmpfile
  end
end

def fetch_git_repo(repo_kind,repo,commit)
  tmpdir=cmd('mktemp -d')

  command = "export http_proxy=#{HTTP_PROXY} https_proxy=#{HTTP_PROXY} GIT_SSL_NO_VERIFY=1 "
  command << "&& git clone -q #{repo} #{tmpdir} "
  command << "&& cd #{tmpdir} "

  if repo_kind == 'gerrit'
    command << "&& git fetch -q #{repo} #{commit}"
    command << "&& git reset -q --hard FETCH_HEAD"
  else
    command << "&& git reset -q --hard #{commit} "
    command << "|| git checkout -q #{commit}"
  end

  cmd(command)

  tmpdir
end

def kabootstrap(nodefile,daemon,repo_kind,commit,version,sources=nil)
  bin=KABOOTSTRAP_BIN
  tmpfile = nil
  frontend=nil
  ret=nil
  i = 0
  begin
    if sources
      updatecfg = {
        'WORKINGDIR' => sources,
        'src' => 'src',
        'lib' => 'src/lib',
      }.to_yaml
      tmpfile = cmd('mktemp')
      File.open(tmpfile,'w'){ |f| f.puts updatecfg }
    end
    begin
      ret=cmd("#{bin} #{KABOOTSTRAP_KERNELS} #{KABOOTSTRAP_ENVS} -f #{nodefile} -d #{daemon} --#{repo_kind} #{commit} -v #{version} #{"-u #{tmpfile}" if tmpfile} #{ENV['KABOOTSTRAP_OPTS']}",false)
      if ret.split("\n")[-1] =~ /^Frontend:\s*([\w\-_\.]+@[\w\-_\.]+)\s*$/
        frontend=Regexp.last_match(1)
      end
      i+=1
    end while frontend.nil? and i<KABOOTSTRAP_RETRIES
  ensure
    cmd("rm -f #{tmpfile}") if tmpfile
  end
  if frontend.nil?
    error("Unable to perform kabootstrap\n=== Error ===\n#{ret}")
  end
  frontend
end
