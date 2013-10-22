require 'rake'
require 'rdoc/task'
require 'rake/packagetask'
require 'fileutils'
require 'tmpdir'
require 'tempfile'

VERSION= "#{File.read('major_version').strip}."\
  "#{File.read('minor_version').strip}."\
  "#{File.read('release_version').strip}"

DEPLOY_USER='deploy'

# Directories
D = {
  :base => File.dirname(__FILE__),
  :build => File.join(File.dirname(__FILE__),'build'),
  :lib => File.join(File.dirname(__FILE__),'lib'),
  :man => File.join(File.dirname(__FILE__),'man'),
  :doc => File.join(File.dirname(__FILE__),'doc'),
  :apidoc => File.join(File.dirname(__FILE__),'doc','api'),
  :bin => File.join(File.dirname(__FILE__),'bin'),
  :sbin => File.join(File.dirname(__FILE__),'sbin'),
  :conf => File.join(File.dirname(__FILE__),'conf'),
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
    :dir => File.join(RbConfig::CONFIG["vendordir"],'kadeploy3'),
    :user => 'root',
    :group => 'root',
    :mode => '644',
  },
  :lib_client => {
    :dir => File.join(RbConfig::CONFIG["vendordir"],'kadeploy3','client'),
    :user => 'root',
    :group => 'root',
    :mode => '644',
  },
  :lib_server => {
    :dir => File.join(RbConfig::CONFIG["vendordir"],'kadeploy3','server'),
    :user => 'root',
    :group => 'root',
    :mode => '644',
  },
  :lib_common => {
    :dir => File.join(RbConfig::CONFIG["vendordir"],'kadeploy3','common'),
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
  :conf => {
    :dir => '/etc/kadeploy3',
    :user => 'root',
    :group => 'root',
    :mode => '644',
  },
  :script => {
    :dir => '/usr/share/doc/kadeploy3/scripts',
    :user => 'root',
    :group => 'root',
    :mode => '640',
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
  :karights3 => 'allows to set the deployment rights to users',
  :kadeploy3d => 'the launcher of Kadeploy server',
  :kaconsole3 =>  'allows to get a console on the deploying nodes',
  :kadeploy3 => 'allows to perform efficient deployments on cluster nodes',
  :kaenv3 => 'allows to manage the Kadeploy environments',
  :kanodes3 => 'allows to get information on the current deployments',
  :kapower3 => 'allows to perform several operations to control the power status of nodes',
  :kareboot3 => 'allows to perform several reboot operations on the nodes involved in a deployment',
  :kastat3 => 'allows to get statistics on the deployments',
}


ENV['KADEPLOY3_LIBS'] = D[:lib]

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
    files += ['Rakefile','License.txt','README','AUTHORS','NEWS']
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

  unless File.exists?(dir)
    sh "mkdir -p #{dir}"
    sh "chown #{opts[:user]}:#{opts[:group]} #{dir}"
    sh "chmod #{opts[:mode]} #{dir}"
    sh "chmod +x #{dir}"
  end
end

def delete_dir(dir)
  dir = INSTALL[dir][:dir] if dir.is_a?(Symbol)
  system("rmdir #{dir.to_s}")
end

def installf(kind,file,filename=nil)
  file = File.join(D[kind],file.to_s) if file.is_a?(Symbol)
  inst = INSTALL[kind]
  raise file if !inst or !File.exist?(file)
  dest = inst[:dir]
  dest = File.join(dest,filename) if filename

  sh "install -o #{inst[:user]} -g #{inst[:group]} -m #{inst[:mode]} #{file} #{dest}"
end

def uninstallf(kind,file,filename=nil)
  file = File.basename(file) unless file.is_a?(Symbol)
  dest = INSTALL[kind][:dir]
  dest = File.join(dest,filename) if filename
  sh "rm -f #{File.join(dest,file.to_s)}"
end


task :default => [:build]

desc "Generate manpages"
task :man => [:man_clean, :man_client, :man_server]
task :man_clean => [:man_client_clean, :man_server_clean ]

desc "Generate client manpages"
task :man_client => :man_client_clean do
  raise "help2man is missing !" unless system('which help2man')

  Dir[File.join(D[:bin],'/*')].each do |bin|
    filename = File.basename(bin)
	  %x{#{bin} --help}
	  sh "COLUMNS=0 help2man --version-string=#{VERSION} -N -n '#{DESC[filename.to_sym]}' -i #{D[:man]}/TEMPLATE -s 1 -o #{D[:man]}/#{filename}.1 #{bin}"
  end
end

desc "Clean manpages files"
task :man_client_clean do
  sh "rm -f #{File.join(D[:man],'*.1')}"
end

desc "Generate server manpages"
task :man_server => :man_server_clean do
  raise "help2man is missing !" unless system('which help2man')

  Dir[File.join(D[:sbin],'*')].each do |bin|
    filename = File.basename(bin)
	  %x{#{bin} --help}
	  sh "COLUMNS=0 help2man --version-string=#{VERSION} -N -n '#{DESC[filename.to_sym]}' -i #{D[:man]}/TEMPLATE -s 8 -o #{D[:man]}/#{filename}.8 #{bin}"
  end
end

desc "Clean manpages files"
task :man_server_clean do
  sh "rm -f #{File.join(D[:man],'*.8')}"
end

desc "Generate the documentation"
task :doc => :doc_clean do
  raise "help2man is missing !" unless system('which help2man')

  Dir.mktmpdir('kadeploy_build-') do |dir|
    Tempfile.open('Kadeploy.tex.complete') do |f|
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

desc "Install the client and the server"
task :install => [:install_client,:install_server]

desc "Uninstall the client and the server"
task :uninstall => [:uninstall_client,:uninstall_server] do
  delete_dir(:lib)
end

desc "Install common files"
task :install_common do
  create_dir(:lib)
  installf(:lib,:'kadeploy3/common.rb')

  create_dir(:lib_common)
  Dir[File.join(D[:lib],'kadeploy3','common','*.rb')].each do |f|
    installf(:lib_common,f)
  end
end

desc "Uninstall common files"
task :uninstall_common do
  Dir[File.join(D[:lib],'kadeploy3','common','*.rb')].each do |f|
    uninstallf(:lib_common,f)
  end
  delete_dir(:lib_common)

  uninstallf(:lib,:'common.rb')
  delete_dir(:lib)
end

desc "Install the client"
task :install_client => [:man_client, :install_common] do
  create_dir(:man1)
  Dir[File.join(D[:man],'*.1')].each do |f|
    installf(:man1,f)
  end

  create_dir(:conf)
  installf(:conf,:'client_conf.yml')

  create_dir(:bin)
  Dir[File.join(D[:bin],'*')].each do |f|
    installf(:bin,File.basename(f).to_sym)
  end

  create_dir(:lib)
  installf(:lib,:'kadeploy3/client.rb')

  create_dir(:lib_client)
  Dir[File.join(D[:lib],'kadeploy3','client','*.rb')].each do |f|
    installf(:lib_client,f)
  end
end

desc "Uninstall the client"
task :uninstall_client => :uninstall_common do
  Dir[File.join(D[:man],'*.1')].each do |f|
    uninstallf(:man1,f)
  end

  Dir[File.join(D[:bin],'*')].each do |f|
    uninstallf(:bin,f.to_sym)
  end
  delete_dir(:bin)

  uninstallf(:conf,:'client_conf.yml')
  delete_dir(:conf)

  Dir[File.join(D[:lib],'kadeploy3','client','*.rb')].each do |f|
    uninstallf(:lib_client,f)
  end
  delete_dir(:lib_client)

  uninstallf(:lib,:'client.rb')
  delete_dir(:lib)
end


desc "Install the server"
task :install_server, [:distrib] => [:man_server, :install_common] do |f,args|
  args.with_defaults(:distrib => 'debian')
  raise "unknown distrib '#{args.distrib}'" unless %w{debian fedora}.include?(args.distrib)
  raise "user #{DEPLOY_USER} not found: useradd --system #{DEPLOY_USER}" unless system("id #{DEPLOY_USER}")

  create_dir(:man8)
  Dir[File.join(D[:man],'*.8')].each do |f|
    installf(:man8,f)
  end

  create_dir(:conf)
  installf(:conf,:'server_conf.yml')
  installf(:conf,:'clusters.yml')
  installf(:conf,:'cmd.yml')
  Dir[File.join(D[:conf],'cluster-*.yml')].each do |f|
    installf(:conf,File.basename(f).to_sym)
  end
  Tempfile.open('kadeploy_version',File.dirname(__FILE__)) do |f|
    f.puts VERSION
    f.close
    installf(:conf,f.path,'version')
  end

  create_dir(:script)
  installf(:script,File.join(D[:scripts],'bootloader','install_grub'))
  installf(:script,File.join(D[:scripts],'bootloader','install_grub2'))
  installf(:script,File.join(D[:scripts],'partitioning','parted-sample'))
  installf(:script,File.join(D[:scripts],'partitioning','fdisk-sample'))

  create_dir(:sbin)
  Dir[File.join(D[:sbin],'*')].each do |f|
    installf(:sbin,File.basename(f).to_sym)
  end

  create_dir(:rc)
  installf(:rc,File.join(D[:addons],'rc',args.distrib,'kadeploy3d'))

  create_dir(:log)

  create_dir(:lib)
  installf(:lib,:'kadeploy3/server.rb')

  create_dir(:lib_server)
  Dir[File.join(D[:lib],'kadeploy3','server','*.rb')].each do |f|
    installf(:lib_server,f)
  end
end

desc "Uninstall the server"
task :uninstall_server => :uninstall_common do
  Dir[File.join(D[:man],'*.8')].each do |f|
    uninstallf(:man8,f)
  end

  Dir[File.join(D[:sbin],'*')].each do |f|
    uninstallf(:sbin,f.to_sym)
  end
  delete_dir(:sbin)

  Dir[File.join(D[:lib],'kadeploy3','server','*.rb')].each do |f|
    uninstallf(:lib_server,f)
  end
  delete_dir(:lib_server)

  uninstallf(:lib,:'server.rb')
  delete_dir(:lib)

  uninstallf(:conf,:'server_conf.yml')
  uninstallf(:conf,:'clusters.yml')
  uninstallf(:conf,:'cmd.yml')
  Dir[File.join(D[:conf],'cluster-*.yml')].each do |f|
    uninstallf(:conf,f.to_sym)
  end
  uninstallf(:conf,:version)
  delete_dir(:conf)

  uninstallf(:script,'install_grub')
  uninstallf(:script,'install_grub2')
  uninstallf(:script,'parted-sample')
  uninstallf(:script,'fdisk-sample')
  delete_dir(:script)

  uninstallf(:rc,'kadeploy3d')
  delete_dir(:rc)

  sh "rm -f #{File.join(INSTALL[:log][:dir],'*')}"
  delete_dir(:log)
end

desc "Install kastafior"
task :install_kastafior do
  create_dir(:bin)
  installf(:bin,File.join(D[:addons],'kastafior','kastafior'))
end

desc "Clean the build directory"
task :build_clean do
  sh "rm -Rf #{D[:build]}"
end

desc "Clean everything"
task :clean => [:man_clean, :doc_clean, :apidoc_clean]

desc "Generate source dir and a tgz package, can be of kind classical or deb, usage: 'rake build[deb]', default: classical"
task :build, [:kind,:dir] => [:build_clean, :man, :doc, :apidoc] do |f,args|
  args.with_defaults(:kind => 'classical')
  D[:build] = File.expand_path(args.dir) if args.dir
  sh "echo '#{VERSION}' > #{File.join(D[:conf],'version')}"
  Rake::PackageTask::new("kadeploy3",VERSION) do |p|
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

  if args.kind == 'deb'
    tmp = File.join(D[:build],"kadeploy")
    sh "mv #{tmp}3-#{VERSION}.tar.gz #{tmp}_#{VERSION}.orig.tar.gz"
    pkgdir = File.join(D[:build],"kadeploy-#{VERSION}")
    sh "mv #{tmp}3-#{VERSION} #{tmp}-#{VERSION}"

    puts "\nTarball created in #{D[:build]}"
    puts "You probably want to:"
    puts "  git tag v#{VERSION}"
    puts "  git push origin HEAD:refs/tags/v#{VERSION}"
  end
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

#desc "Launch the test-suite"
#task :test do
#  raise 'Not implemented !'
#end
