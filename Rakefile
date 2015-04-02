require 'rake'
require 'rake/packagetask'
require 'rbconfig'
require 'fileutils'
require 'tmpdir'
require 'tempfile'
require 'date'

MAJOR_VERSION=File.read('major_version').strip
MINOR_VERSION=File.read('minor_version').strip
RELEASE_VERSION=File.read('release_version').strip
if RELEASE_VERSION == 'git'
  Object.instance_eval{remove_const(:RELEASE_VERSION)}
  RELEASE_VERSION="git+#{Time.now.strftime('%Y%m%d%H%M%S')}"
  if system('git status > /dev/null')
    tmp = RELEASE_VERSION
    Object.instance_eval{remove_const(:RELEASE_VERSION)}
    RELEASE_VERSION="#{tmp}+#{%x{git log --pretty=format:'%h' -n 1}}"
  end
end

VERSION="#{MAJOR_VERSION}.#{MINOR_VERSION}.#{RELEASE_VERSION}"

DEPLOY_USER='deploy'

def vendordir(*args)
  if RUBY_VERSION >= "1.9.0"
    File.join(RbConfig::CONFIG["vendordir"],*args)
  else
    File.join(RbConfig::CONFIG["vendorlibdir"],*args)
  end
end
# Directories
D = {
  :base => File.dirname(__FILE__),
  :build => '/tmp/kabuild',
  :lib => File.join(File.dirname(__FILE__),'lib'),
  :man => File.join(File.dirname(__FILE__),'man'),
  :doc => File.join(File.dirname(__FILE__),'doc'),
  :apidoc => File.join(File.dirname(__FILE__),'doc','api'),
  :bin => File.join(File.dirname(__FILE__),'bin'),
  :sbin => File.join(File.dirname(__FILE__),'sbin'),
  :conf => File.join(File.dirname(__FILE__),'conf'),
  :keys => File.join(File.dirname(__FILE__),'keys'),
  :scripts => File.join(File.dirname(__FILE__),'scripts'),
  :pkg => File.join(File.dirname(__FILE__),'pkg'),
  :addons => File.join(File.dirname(__FILE__),'addons'),
}

FILES = {
  :apidoc => File.join(D[:apidoc],"api_specs-#{VERSION}"),
  :doc => File.join(D[:doc],"Kadeploy-#{VERSION}"),
}

INSTALL = {
  :man1 => {
    :dir => '/usr/share/man/man1',
    :user => 'root',
    :group => 'root',
    :mode => '644',
  },
  :man8 => {
    :dir => '/usr/share/man/man8',
    :user => 'root',
    :group => 'root',
    :mode => '644',
  },
  :lib => {
    :dir => vendordir('kadeploy3'),
    :user => 'root',
    :group => 'root',
    :mode => '644',
  },
  :lib_client => {
    :dir => vendordir('kadeploy3','client'),
    :user => 'root',
    :group => 'root',
    :mode => '644',
  },
  :lib_server => {
    :dir => vendordir('kadeploy3','server'),
    :user => 'root',
    :group => 'root',
    :mode => '644',
  },
  :lib_common => {
    :dir => vendordir('kadeploy3','common'),
    :user => 'root',
    :group => 'root',
    :mode => '644',
  },
  :lib_kaadmin=> {
    :dir => vendordir('kadeploy3','kaadmin'),
    :user => 'root',
    :group => 'root',
    :mode => '644',
  },
  :log => {
    :dir => '/var/log/kadeploy3',
    :user => 'root',
    :group => DEPLOY_USER,
    :mode => '770',
  },
  :run => {
    :dir => '/var/run/kadeploy3d',
    :user => DEPLOY_USER,
    :group => 'root',
    :mode => '755',
  },
  :conf => {
    :dir => '/etc/kadeploy3',
    :user => 'root',
    :group => 'deploy',
    :mode => '640',
  },
  :keys => {
    :dir => '/etc/kadeploy3/keys',
    :user => 'root',
    :group => 'deploy',
    :mode => '640',
  },
  :doc => {
    :dir => '/usr/share/doc/kadeploy3',
    :user => 'root',
    :group => 'root',
    :mode => '644',
  },
  :script => {
    :dir => '/usr/share/doc/kadeploy3/scripts',
    :user => 'root',
    :group => 'root',
    :mode => '644',
  },
  :bin => {
    :dir => '/usr/bin',
    :user => 'root',
    :group => 'root',
    :mode => '755',
  },
  :sbin => {
    :dir => '/usr/sbin',
    :user => 'root',
    :group => 'root',
    :mode => '755',
  },
  :rc => {
    :dir => '/etc/init.d',
    :user => 'root',
    :group => 'root',
    :mode => '755',
  },
}

DESC = {
  :karights3 => 'manage users deployment rights',
  :kadeploy3d => 'Kadeploy server',
  :kaconsole3 =>  'access the console of deploying nodes',
  :kadeploy3 => 'Kadeploy client -- perform efficient deployments on cluster nodes',
  :kaenv3 => 'manage the Kadeploy environments',
  :kanodes3 => 'get information on the current deployments',
  :kapower3 => 'control the power status of nodes',
  :kareboot3 => 'perform reboot operations on the nodes involved in a deployment',
  :kastat3 => 'get statistics on the deployments',
  :kaadmin3 => 'administration stuff for Kadeploy (image installer, migration script,...)',
}


ENV['KADEPLOY3_LIBS'] = D[:lib]
ENV['KADEPLOY3_VERSION'] = VERSION

def self.sources()
  if system('git status > /dev/null')
    files = %x{git ls-tree --name-only -r -t HEAD}.split("\n")
    files += Dir['man/*.1']
    files += Dir['man/*.8']
    files += Dir['doc/*.pdf']
    files += Dir['doc/api/*.html']
    files
  else
    files = []
    files << 'lib/**/*.rb'
    files << 'conf/*'
    files << 'scripts/**/*'
    files << 'db/*'
    files << 'bin/*'
    files << 'sbin/*'
    files << 'man/*'
    files << 'doc/**/*'
    files << 'addons/**/*'
    files << 'test/*'
    files += ['Rakefile','License.txt','README','AUTHORS','NEWS','major_version','minor_version','release_version']
    files
  end
end

def create_dir(dir,opts={})
  if dir.is_a?(Symbol)
    tmp = INSTALL[dir]
    dir = tmp[:dir]
    opts[:user] = tmp[:user]
    opts[:group] = tmp[:group]
    opts[:mode] = tmp[:mode]
  else
    opts = {:user=>'root',:group=>'root',:mode=>'640'}.merge(opts)
  end

  dir = File.join(@root_dir,dir) if @root_dir
  unless File.exists?(dir)
    sh "mkdir -p #{dir}"
    sh "chown #{opts[:user]}:#{opts[:group]} #{dir}"
    sh "chmod #{opts[:mode]} #{dir}"
    sh "chmod +x #{dir}"
  end
end

def delete_dir(dir)
  dir = INSTALL[dir][:dir] if dir.is_a?(Symbol)
  dir = File.join(@root_dir,dir) if @root_dir
  system("rmdir -p #{dir.to_s}")
end

def installf(kind,file,filename=nil,override=true)
  file = File.join(D[kind],file.to_s) if file.is_a?(Symbol)
  inst = INSTALL[kind]
  raise file if !inst or !File.exist?(file)
  dest = inst[:dir]
  if filename
    dest = File.join(dest,filename) 
  else
    dest = File.join(dest,File.basename(file))
  end
  dest = File.join(@root_dir,dest) if @root_dir
  dest +='.dist' if !override && File.exist?(dest)
  sh "install -o #{inst[:user]} -g #{inst[:group]} -m #{inst[:mode]} #{file} #{dest}"
end

def uninstallf(kind,file,filename=nil)
  file = File.basename(file) unless file.is_a?(Symbol)
  dest = INSTALL[kind][:dir]
  dest = File.join(dest,filename) if filename
  dest = File.join(@root_dir,dest) if @root_dir
  sh "rm -f #{File.join(dest,file.to_s)}*"
end

def gen_man(file,level)
  filename = File.basename(file)
  %x{#{file} --help}
  sh "COLUMNS=0 help2man -N -n '#{DESC[filename.to_sym]}' -i #{D[:man]}/TEMPLATE -s #{level} -o #{D[:man]}/#{filename}.#{level} #{file}"
end

def deb_versions()
  if RELEASE_VERSION =~ /git|alpha|rc/
    [
      "#{MAJOR_VERSION}.#{MINOR_VERSION}~#{RELEASE_VERSION}",
      "v#{MAJOR_VERSION}.#{MINOR_VERSION}_#{RELEASE_VERSION}",
    ]
  else
    [
      "#{MAJOR_VERSION}.#{MINOR_VERSION}.#{RELEASE_VERSION}",
      "v#{MAJOR_VERSION}.#{MINOR_VERSION}.#{RELEASE_VERSION}",
    ]
  end
end


task :default => [:build]

desc "Generate manpages"
task :man => [:man_clean, :man_client, :man_server]
task :man_clean => [:man_client_clean, :man_server_clean ]

desc "Generate client manpages"
task :man_client => :man_client_clean do
  raise "help2man is missing !" unless system('which help2man')

  Dir[File.join(D[:bin],'/*')].each do |bin|
    gen_man(bin,1)
  end
  gen_man(File.join(D[:sbin],'karights3'),8)
end

desc "Clean manpages files"
task :man_client_clean do
  sh "rm -f #{File.join(D[:man],'*.1')}"
end

desc "Generate server manpages"
task :man_server => :man_server_clean do
  raise "help2man is missing !" unless system('which help2man')

  Dir[File.join(D[:sbin],'kadeploy3d'),File.join(D[:sbin],'kaimagehelper3')].each  do |bin|
    gen_man(bin,8)
  end
end

desc "Clean manpages files"
task :man_server_clean do
  sh "rm -f #{File.join(D[:man],'*.8')}"
end

desc "Generate the documentation"
task :doc => :doc_clean do
  raise "help2man is missing !" unless system('which help2man')

  Dir.mktmpdir('kadeploy_build-',File.dirname(__FILE__)) do |dir|
    f = Tempfile.new('Kadeploy.tex.complete',File.dirname(__FILE__))
    begin
      # Replace the __HELP_..._HELP__ pattern by the --help of the binaries
      content = File.read("#{D[:doc]}/Kadeploy.tex")
      Dir[File.join(D[:bin],'*'),File.join(D[:sbin],'*')].each do |bin|
        help = %x{#{bin} --help}
        content.gsub!(/__HELP_#{File.basename(bin)}_HELP__/,help)
      end
      f.write(content)
      f.close

      # Generate the documentation
      sh "pdflatex -jobname '#{File.basename(FILES[:doc])}' --output-directory=#{dir} #{f.path}"
      sh "pdflatex -jobname '#{File.basename(FILES[:doc])}' --output-directory=#{dir} #{f.path}"
    ensure
      f.close
      f.unlink
    end
    sh "ln #{File.join(dir,'*.pdf')} #{D[:doc]}"
  end
end

desc "Clean documentation files"
task :doc_clean do
  sh "rm -f #{File.join(D[:doc],'*.pdf')}"
end

desc "Generate the REST API documentation"
task :apidoc => :apidoc_clean do
  sh "#{D[:apidoc]}/apidoc 'Kadeploy #{VERSION} REST API specifications' #{D[:apidoc]}/api.css #{Dir[File.join(D[:apidoc],'*.api')].join(' ')} > #{FILES[:apidoc]}.html"
end

desc "Clean the REST API documentation files"
task :apidoc_clean do
  sh "rm -f #{File.join(D[:apidoc],'*.html')}"
end

task :prepare, [:root_dir] do |f,args|
  @root_dir = args.root_dir if args.root_dir and !args.root_dir.empty?
end

desc "Install the client and the server"
task :install, [:root_dir,:distrib] => [:prepare,:install_client,:install_server]

desc "Uninstall the client and the server"
task :uninstall, [:root_dir] => [:uninstall_client,:uninstall_server] do
  delete_dir(:lib)
end

desc "Install common files"
task :install_common, [:root_dir,:distrib] => :prepare do
  create_dir(:lib)
  installf(:lib,:'kadeploy3/common.rb')

  create_dir(:lib_common)
  Dir[File.join(D[:lib],'kadeploy3','common','*.rb')].each do |f|
    installf(:lib_common,f)
  end
end

desc "Uninstall common files"
task :uninstall_common, [:root_dir] => :prepare do
  Dir[File.join(D[:lib],'kadeploy3','common','*.rb')].each do |f|
    uninstallf(:lib_common,f)
  end
  delete_dir(:lib_common)

  uninstallf(:lib,:'common.rb')
  delete_dir(:lib)
end

desc "Install the client"
task :install_client, [:root_dir,:distrib] => [:prepare, :man_client, :install_common] do
  create_dir(:man1)
  Dir[File.join(D[:man],'*.1')].each do |f|
    installf(:man1,f)
  end
  create_dir(:man8)
  installf(:man8,File.join(D[:man],'karights3.8'))

  create_dir(:conf)
  installf(:conf,:'client.conf',nil,false)

  create_dir(:bin)
  Dir[File.join(D[:bin],'*')].each do |f|
    installf(:bin,File.basename(f).to_sym)
  end

  create_dir(:sbin)
  installf(:sbin,:karights3)

  create_dir(:lib)
  installf(:lib,:'kadeploy3/client.rb')

  create_dir(:lib_client)
  Dir[File.join(D[:lib],'kadeploy3','client','*.rb')].each do |f|
    installf(:lib_client,f)
  end
end

desc "Uninstall the client"
task :uninstall_client, [:root_dir] => [:prepare, :uninstall_common] do
  Dir[File.join(D[:man],'*.1')].each do |f|
    uninstallf(:man1,f)
  end
  uninstallf(:man8,File.join(D[:man],'karights3.8'))

  Dir[File.join(D[:bin],'*')].each do |f|
    uninstallf(:bin,File.basename(f).to_sym)
  end
  delete_dir(:bin)

  uninstallf(:sbin,:'karights3')
  delete_dir(:sbin)

  uninstallf(:conf,:'client.conf')
  delete_dir(:conf)

  Dir[File.join(D[:lib],'kadeploy3','client','*.rb')].each do |f|
    uninstallf(:lib_client,f)
  end
  delete_dir(:lib_client)

  uninstallf(:lib,:'client.rb')
  delete_dir(:lib)
end

desc "Install the server"
task :install_server, [:root_dir,:distrib] => [:prepare,:man_server, :install_common] do |f,args|
  args.with_defaults(:distrib => 'debian')
  raise "unknown distrib '#{args.distrib}'" unless %w{debian redhat}.include?(args.distrib)
  raise "user #{DEPLOY_USER} not found: useradd --system #{DEPLOY_USER}" unless system("id #{DEPLOY_USER}")

  create_dir(:man8)
  installf(:man8,File.join(D[:man],'kadeploy3d.8'))

  create_dir(:conf)
  create_dir(:keys)
  installf(:conf,:'server.conf',nil,false)
  installf(:conf,:'clusters.conf',nil,false)
  installf(:conf,:'command.conf',nil,false)
  Dir[File.join(D[:conf],'*-cluster.conf')].each do |f|
    installf(:conf,File.basename(f).to_sym,nil,false)
  end
  Tempfile.open('kadeploy_version',File.dirname(__FILE__)) do |f|
    f.puts VERSION
    f.close
    installf(:conf,f.path,'version')
  end

  create_dir(:doc)
  sh "gzip -c #{File.join(D[:addons],'kastafior','kastafior')} > #{File.join(D[:addons],'kastafior','kastafior')}.gz"
  sh "gzip -c #{File.join(D[:addons],'kascade','kascade')} > #{File.join(D[:addons],'kascade','kascade')}.gz"
  installf(:doc,File.join(D[:addons],'kastafior','kastafior.gz'))
  installf(:doc,File.join(D[:addons],'kascade','kascade.gz'))
  sh "rm #{File.join(D[:addons],'kastafior','kastafior')}.gz"
  sh "rm #{File.join(D[:addons],'kascade','kascade')}.gz"

  create_dir(:script)
  installf(:script,File.join(D[:scripts],'bootloader','install_grub'))
  installf(:script,File.join(D[:scripts],'bootloader','install_grub2'))
  installf(:script,File.join(D[:scripts],'partitioning','parted-sample'))
  installf(:script,File.join(D[:scripts],'partitioning','parted-sample-simple'))
  installf(:script,File.join(D[:scripts],'partitioning','fdisk-sample'))

  create_dir(:sbin)
  installf(:sbin,:kadeploy3d)

  create_dir(:rc)
  installf(:rc,File.join(D[:addons],'rc',args.distrib,'kadeploy'))

  create_dir(:log)
  create_dir(:run)

  create_dir(:lib)
  installf(:lib,:'kadeploy3/server.rb')

  create_dir(:lib_server)
  Dir[File.join(D[:lib],'kadeploy3','server','*.rb')].each do |f|
    installf(:lib_server,f)
  end
end

desc "Uninstall the server"
task :uninstall_server, [:root_dir] => [:prepare, :uninstall_common] do
  uninstallf(:man8,File.join(D[:man],'kadeploy3d.8'))

  uninstallf(:sbin,:'kadeploy3d')
  delete_dir(:sbin)

  Dir[File.join(D[:lib],'kadeploy3','server','*.rb')].each do |f|
    uninstallf(:lib_server,f)
  end
  delete_dir(:lib_server)

  uninstallf(:lib,:'server.rb')
  delete_dir(:lib)

  uninstallf(:conf,:'server.conf')
  uninstallf(:conf,:'clusters.conf')
  uninstallf(:conf,:'command.conf')
  Dir[File.join(D[:conf],'*-cluster.conf')].each do |f|
    uninstallf(:conf,File.basename(f).to_sym)
  end
  uninstallf(:conf,:version)
  delete_dir(:conf)

  uninstallf(:script,'install_grub')
  uninstallf(:script,'install_grub2')
  uninstallf(:script,'parted-sample')
  uninstallf(:script,'parted-sample-simple')
  uninstallf(:script,'fdisk-sample')
  delete_dir(:script)

  uninstallf(:doc,'kastafior.gz')
  uninstallf(:doc,'kascade.gz')
  delete_dir(:doc)

  uninstallf(:rc,'kadeploy')
  delete_dir(:rc)

  logs = File.join(INSTALL[:log][:dir],'*')
  logs = File.join(@root_dir,logs) if @root_dir
  sh "rm -f #{logs}"
  delete_dir(:log)

  runs = File.join(INSTALL[:run][:dir],'*')
  runs = File.join(@root_dir,runs) if @root_dir
  sh "rm -f #{runs}"
  delete_dir(:run)
end

desc "Install kastafior"
task :install_kastafior, [:root_dir,:distrib] => [:prepare] do
  create_dir(:bin)
  installf(:bin,File.join(D[:addons],'kastafior','kastafior'))
end

desc "Install kascade"
task :install_kascade, [:root_dir,:distrib] => [:prepare] do
  create_dir(:bin)
  installf(:bin,File.join(D[:addons],'kascade','kascade'))
end

desc "Install Kaadmin"
task :install_kaadmin, [:root_dir,:distrib] => [:prepare] do
  create_dir(:sbin)
  installf(:sbin,File.join(D[:addons],'kaadmin','sbin','kaadmin3'))
  create_dir(:lib)
  installf(:lib,File.join(D[:addons],'kaadmin','lib','kadeploy3','kaadmin.rb'))
  create_dir(:lib_kaadmin)
  Dir[File.join(D[:addons],'kaadmin','lib','kadeploy3','kaadmin','*.rb')].each do |f|
    installf(:lib_kaadmin,f)
  end
end

desc "Clean the build directory"
task :build_clean do
  sh "rm -Rf #{D[:build]}"
end

desc "Clean everything"
task :clean => [:man_clean, :doc_clean, :apidoc_clean]

task :build_prepare, [:dir] do |f,args|
  D[:build] = File.expand_path(args.dir) if args.dir and !args.dir.empty?
end

desc "Generate source dir and a tgz package, can be of kind classical or deb, usage: 'rake build[deb]', default: classical"
task :build, [:dir,:kind] => [:build_prepare, :build_clean, :man, :doc, :apidoc] do |f,args|
  args.with_defaults(:kind => 'classical')
  sh "echo '#{VERSION}' > #{File.join(D[:conf],'version')}"
  Rake::PackageTask::new("kadeploy",VERSION) do |p|
    p.need_tar_gz = true
    p.package_dir = D[:build]
    src = sources()
    p.package_files.include(*src)
    p.package_files.include('conf/version')
  end
  Rake::Task[:package].invoke
  sh "rm #{File.join(D[:conf],'version')}"
  Rake::Task[:clean].reenable
  Rake::Task[:doc_clean].reenable
  Rake::Task[:apidoc_clean].reenable
  Rake::Task[:man_clean].reenable
  Rake::Task[:man_client_clean].reenable
  Rake::Task[:man_server_clean].reenable
  Rake::Task[:clean].invoke
  Rake::Task[:build_deb].invoke if args.kind == 'deb'
end

desc "Build an origin archive for debian packaging"
task :build_deb, [:dir] => :build do
  tmp = File.join(D[:build],"kadeploy")
  sh "mv #{tmp}-#{VERSION}.tar.gz #{tmp}_#{VERSION}.orig.tar.gz"
end

desc "Show information about the Debian package building process"
task :deb_info do |f, args|
  suff = args.branch_suffix || ''
  deb_version, tag_version = deb_versions()
  puts <<-EOF
## When you package is ready, you will need to:
### Push upstream and merge modifications and tags
 First, push your changes on the master or 3.X branch. EXAMPLES:
  git push origin master:refs/for/master
  OR git push origin 3.2:refs/for/3.2
 Then:
  git push origin upstream#{suff}:refs/for/upstream#{suff}
  git push origin debian#{suff}:refs/for/debian#{suff}
  git push origin #{tag_version}:refs/tags/#{tag_version}
  git push origin pristine-tar#{suff}:refs/for/pristine-tar#{suff}
  git push origin upstream#{suff}/#{tag_version}:refs/tags/upstream#{suff}/#{tag_version}
### After the packaging work, tag the final Debian package, push the tag:
  git commit -m "Update Debian changelog for #{deb_version}" debian/changelog
  git-buildpackage --git-tag-only --git-no-hooks --git-ignore-new
  git push origin debian#{suff}/#{tag_version}-1:refs/tags/debian#{suff}/#{tag_version}-1
### If you want to build a -dev package, use:
  DEB_BUILD_OPTIONS=devpkg=dev git-buildpackage -us -uc
EOF
end

desc "Generate debian package (Be careful it will break your Git repository !)"
task :deb, [:dir,:branch_suffix] => :build_deb do |f,args|
  suff = args.branch_suffix || ''
  deb_version, tag_version = deb_versions()
  sh "git tag -d '#{tag_version}'; git tag -am '#{tag_version}' '#{tag_version}'"
  sh "git tag -d 'upstream#{suff}/#{tag_version}'; true"
  sh "git branch -D upstream#{suff}; git checkout -b upstream#{suff} origin/upstream#{suff}"
  sh "git branch -D debian#{suff}; git checkout -b debian#{suff} origin/debian#{suff}"
  sh "git checkout debian#{suff}"
  sh "git-import-orig "\
    "--upstream-version=#{deb_version} "\
    "--upstream-vcs-tag='#{tag_version}' "\
    "#{File.join(D[:build],"kadeploy_#{VERSION}.orig.tar.gz")}"
  sh "dch -v '#{deb_version}-1' 'New Git snapshot based on #{tag_version}.'"
  sh 'git-buildpackage --git-ignore-new -uc -us || true'
  Rake::Task[:build_clean].reenable
  Rake::Task[:build_clean].invoke
  Rake::Task[:deb_info].invoke
end

desc "Generate debian changelog file"
task :deb_changelog, [:dir] do |f,args|
  args.with_defaults(:dir => D[:pkg])
  news = File.read(File.join(D[:base],'NEWS'))
  news = news.split(/##.*##/).select{|v| !v.strip.empty?}[0].split("\n")
  news = news.grep(/^\s*\*/).collect{|v| v.gsub(/^\s*\*\s*/,'')}
  sh "dch --create -v #{VERSION} --package kadeploy --empty --changelog #{File.join(args.dir,'changelog')}"
  news.each do |n|
    sh "dch -a \"#{n}\" --changelog #{File.join(args.dir,'changelog')}"
  end
end

desc "Generate rpm package"
task :rpm, [:dir] => :build do
  sh "mkdir -p #{File.join(D[:build],'SOURCES')}"
  sh "mv #{File.join(D[:build],'*')} #{File.join(D[:build],'SOURCES')} || true"
  specs = File.read(File.join(D[:pkg],'redhat','kadeploy.spec.in'))
  specs.gsub!(/KADEPLOY3_LIBS/,INSTALL[:lib][:dir])
  specs.gsub!(/MAJOR_VERSION/,MAJOR_VERSION)
  specs.gsub!(/MINOR_VERSION/,MINOR_VERSION)
  specs.gsub!(/RELEASE_VERSION/,RELEASE_VERSION)
  File.open(File.join(D[:build],'kadeploy.spec'),'w'){|f| f.write specs}
  sh "rpmbuild --define '_topdir #{D[:build]}' -ba #{File.join(D[:build],'kadeploy.spec')}"
end

#desc "Launch the test-suite"
#task :test do
#  raise 'Not implemented !'
#end
