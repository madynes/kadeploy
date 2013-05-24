require 'yaml'
require 'rubygems'
require 'net/ssh'

KADEPLOY_BIN=ENV['KADEPLOY_BIN']||'kadeploy3'
KADEPLOY_RETRIES=3
KABOOTSTRAP_BIN=ENV['KABOOTSTRAP_BIN']||'/home/lsarzyniec/kabootstrap'
ENVIRONMENT=ENV['KADEPLOY_ENV']||'squeeze-x64-base'
KABOOTSTRAP_KERNELS=ENV['KABOOTSTRAP_KERNELS']||'/home/lsarzyniec/kernels'
KABOOTSTRAP_ENVS=ENV['KABOOTSTRAP_ENVS']||'/home/lsarzyniec/envs'
#KABOOTSTRAP_OPTS
KABOOTSTRAP_RETRIES=4
GIT_REPO=ENV['GIT_REPO']||'https://gforge.inria.fr/git/kadeploy3/kadeploy3.git'
#GIT_REV
HTTP_PROXY=ENV['HTTP_PROXY']||'http://proxy:3128'
SSH_OPTIONS=ENV['SSH_OPTIONS']||'-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=publickey -o ConnectTimeout=12 -o ConnectionAttempts=3'
SSH_KEY="#{ENV['HOME']}/.ssh/id_rsa"

TMP_DIR='/tmp/testsuite'
TEST_DIR=File.join(TMP_DIR,'test')
TEST_CONFIG='test_config.yml'
TEST_KADEPLOY='test_kadeploy.rb'
TEST_KAREBOOT='test_kareboot.rb'
TEST_KAPOWER='test_kapower.rb'
TEST_KAENV='test_kaenv.rb'

def cmd(cmd,checkstatus=true)
  puts "=== COMMAND: #{cmd} ===" if ENV['DEBUG']
  ret=`#{cmd}`
  if checkstatus and !$?.success?
    error("Unable to perform the command: #{cmd}\n=== Error ===\n#{ret}")
  end
  puts "=== STDOUT ===\n#{ret}" if ret and !ret.empty? and ENV['DEBUG']
  ret.strip
end

def scp(user,host,source,dest)
  cmd("scp -q #{SSH_OPTIONS} -r #{source} #{user}@#{host}:#{dest}")
end

def ssh(user,host,cmd,checkstatus=true,password='grid5000')
  #cmd("ssh #{SSH_OPTIONS} #{host} \"#{cmd}\"")
  stdout = ""
  stderr = ""
  status = 1
  Net::SSH.start(host,user,:keys => SSH_KEY, :password=>password) do |ssh|
    ssh.open_channel do |channel|
      channel.exec(cmd) do |ch, success|
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

def fetch_git_repo(version)
  tmpdir=cmd('mktemp -d')
  commit=ENV['GIT_REV']||version
  cmd(
    "export https_proxy=#{HTTP_PROXY} GIT_SSL_NO_VERIFY=1 "\
    "&& git clone #{GIT_REPO} #{tmpdir} "\
    "&& cd #{tmpdir} "\
    "&& git checkout #{commit}"
  )
  tmpdir
end

def kabootstrap(nodefile,daemon,commit,version,sources=nil)
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
      ret=cmd("#{bin} #{KABOOTSTRAP_KERNELS} #{KABOOTSTRAP_ENVS} -f #{nodefile} -d #{daemon} --git #{commit} -v #{version} #{"-u #{tmpfile}" if tmpfile} #{ENV['KABOOTSTRAP_OPTS']} ",false)
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
