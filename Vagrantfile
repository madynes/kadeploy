# Samples:
#   DEV=1 INSTALL=build vagrant up
#   DISTRIB=redhat INSTALL=package vagrant up
#   PKG=1 vagrant up # sources files in /home/vagrant/kadeploy3/
#   NODES=4 DISTRIB=redhat vagrant up
#   NODES=2 GUI=1 vagrant up
#   NODES=4 vagrant destroy -f
#
# Configure/Tune the kabootstrap receipe: puppet/modules/kabootstrap/README
#
# !!! Be careful, once the VMs were deployed with kadeploy it's not possible to re-launch them using the "vagrant up" command (pxe boot profiles)

require 'yaml'

TAKTUK_VERSION = '3.7.5-1.el6.x86_64'
TAKTUK_URL = 'http://kadeploy3.gforge.inria.fr/files/taktuk'

Vagrant.configure("2") do |config|
  config.vm.boot_timeout = 50
  install = (ENV['INSTALL'] || 'default').downcase
  install = 'default' unless install =~ /(packages|build|sources|repository)/
  distrib = (ENV['DISTRIB'] || 'debian').downcase
  mock = ENV['NODES'] == '0'
  if !mock
    nodes = {}
    unless ENV['PKG']
      (ENV['NODES'] || 1).to_i.times do |i|
        nodes["node-#{i+1}"] = {
          'mac' => '02:00:02:00:02:%02x'%(i+1),
          'ip'  => "10.0.10.#{i+2}" # The first IP of the network is used by the host
        }
      end
      File.open('puppet/hiera/nodes.yaml','w') do |f|
        f.write({'kabootstrap::nodes' => nodes}.to_yaml)
      end
    end
  end

  # Setup the service machine
  config.vm.define :kadeploy do |master|
    if Vagrant::VERSION >= "1.5.0"
      if distrib == 'redhat'
        master.vm.box = 'chef/centos-6.5'
      else
        master.vm.box = 'chef/debian-7.4'
      end
    else
      if distrib == 'redhat'
        master.vm.box = 'centos-6.5'
        master.vm.box_url =
          "https://vagrantcloud.com/chef/centos-6.5/version/1/provider/virtualbox.box"
      else
        master.vm.box = 'debian-7.4'
        master.vm.box_url =
          "https://vagrantcloud.com/chef/debian-7.4/version/1/provider/virtualbox.box"
      end
    end

    master.vm.hostname = 'kadeploy'
    if !mock
      master.vm.network :private_network, ip: '10.0.10.253'
      master.vm.provider :virtualbox do |vb|
        vb.cpus = 2
        vb.memory = 1024
        vb.customize ["modifyvm", :id, "--nic1", "nat"]
        vb.customize ["modifyvm", :id, "--nic2", "hostonly"]
        vb.customize ["modifyvm", :id, "--hostonlyadapter2", "vboxnet0"]
      end
    else
      master.vm.provider :virtualbox do |vb|
        vb.memory = 1024
      end
    end

    if ENV['http_proxy']
      master.vm.provision :shell, inline:
        "echo 'export http_proxy=#{ENV['http_proxy'].strip}' >> /etc/profile"
    end
    if ENV['https_proxy']
      master.vm.provision :shell, inline:
        "echo 'export https_proxy=#{ENV['https_proxy'].strip}' >> /etc/profile"
    end

    if distrib == 'redhat'
      master.vm.provision :shell, inline: 'yum check-update; true'
      master.vm.provision :shell, inline: 'yum install -y ruby rubygems redhat-lsb nc'
      # Install TakTuk
      master.vm.provision :shell, inline: "yum localinstall -y #{TAKTUK_URL}/taktuk-libs-#{TAKTUK_VERSION}.rpm"
      master.vm.provision :shell, inline: "yum localinstall -y #{TAKTUK_URL}/taktuk-devel-#{TAKTUK_VERSION}.rpm"
      master.vm.provision :shell, inline: "yum localinstall -y #{TAKTUK_URL}/taktuk-#{TAKTUK_VERSION}.rpm"
    else
      master.vm.provision :shell, inline: 'DEBIAN_FRONTEND=noninteractive apt-get update'
      master.vm.provision :shell, inline: 'DEBIAN_FRONTEND=noninteractive apt-get install -y ruby rubygems lsb-release'
    end
    master.vm.provision :shell, inline: 'gem install --no-ri --no-rdoc facter puppet hiera'
    if mock
      master.vm.provision 'puppet' do |puppet|
        puppet.manifests_path = 'addons/vagrant-mock/manifests'
        puppet.module_path = 'addons/vagrant-mock/modules' 
        puppet.manifest_file  = "default.pp"
        puppet.options = "--verbose --debug" if ENV['DEBUG']
      end
    else
      master.vm.provision :shell, inline: 'chattr -i /etc/resolv.conf' # disable the hack that avoid DHCP to change the resolv.conf file
      master.vm.provision 'puppet' do |puppet|
        puppet.hiera_config_path = 'puppet/hiera.yaml'
        puppet.manifests_path = 'puppet/manifests'
        puppet.module_path = 'puppet/modules'
        if ENV['PKG'] # Only install dependencies to build Kadeploy packages
          puppet.manifest_file = 'deps.pp'
        else # Install the service
          puppet.manifest_file = "hiera.pp"
        end
        facter = {}
        facter['http_proxy'] = ENV['http_proxy'] if ENV['http_proxy'] and !ENV['http_proxy'].empty?
        facter['install_kind'] = install
        puppet.facter = facter
        puppet.options = "--verbose --debug" if ENV['DEBUG']
      end
      master.vm.provision :shell, inline: 'chattr +i /etc/resolv.conf' # enable the hack that avoid DHCP to change the resolv.conf file
    end

    if ENV['PKG']
      gerrit='https://helpdesk.grid5000.fr/gerrit/kadeploy3'
      repodir='/home/vagrant/kadeploy3'
      gitopts="--git-dir=#{repodir}/.git --work-tree=#{repodir}"
      # Create a copy of the sources directory
      master.vm.provision :shell, inline:
        "rm -Rf #{repodir}; cp -R /vagrant #{repodir}"
      # Clean the git directory
      master.vm.provision :shell, inline:
        "git #{gitopts} clean -ffd"
      # Configure the repository for gerrit (use https not to copy SSH keys)
      master.vm.provision :shell, inline:
        "git #{gitopts} remote set-url origin #{gerrit}"
      master.vm.provision :shell, inline:
        "git #{gitopts} config user.name '#{`git config user.name`.strip}'"
      master.vm.provision :shell, inline:
        "git #{gitopts} config user.email '#{`git config user.email`.strip}'"
      master.vm.provision :shell, inline:
        "git #{gitopts} config credential.helper cache"
      master.vm.provision :shell, inline:
        "chown -R vagrant:vagrant #{repodir}"
    elsif ENV['DEV'] # For development purpose
      # synced_folder are conflicting with /vagrant during the installation process
      master.vm.provision :shell, inline:
        'rm -Rf /usr/lib/ruby/vendor_ruby/kadeploy3'
      master.vm.provision :shell, inline:
        'ln -sf /vagrant/lib/kadeploy3 /usr/lib/ruby/vendor_ruby/kadeploy3'
      master.vm.provision :shell, inline:
        'for bin in /vagrant/bin/*; do ln -sf $bin /usr/bin/; done'
      master.vm.provision :shell, inline:
        'for bin in /vagrant/sbin/*; do ln -sf $bin /usr/sbin/; done'
      master.vm.provision :shell, inline:
        'ln -sf /vagrant/addons/rc/debian/kadeploy /etc/init.d/'
    end

    if !ENV['PKG'] && !mock
      master.vm.provision :shell, inline:
        'kaenv3 -a /vagrant/addons/vagrant/wheezy-min.dsc; true'
    end
  end

  if !mock
    # Setup virtual nodes
    nodes.each_pair do |name,node|
      config.vm.define name do |slave|
        slave.vm.box = 'tcl'
        slave.vm.box_url = 'http://kadeploy3.gforge.inria.fr/files/tcl.box'

        slave.vm.provider :virtualbox do |vb|
          vb.gui = true if ENV['GUI']
          vb.memory = 384
          vb.customize ["modifyvm", :id, "--boot1", "net"]
          vb.customize ["modifyvm", :id, "--macaddress1", node['mac'].delete(':')]
          vb.customize ["modifyvm", :id, "--nic1", "hostonly"]
          vb.customize ["modifyvm", :id, "--nictype1", "82540EM"]
          vb.customize ["modifyvm", :id, "--hostonlyadapter1", "vboxnet0"]
          # Disable USB since it's not necessary and depends on extra modules
          vb.customize ["modifyvm", :id, "--usbehci", "off"]
          vb.customize ["modifyvm", :id, "--usb", "off"]
        end
        slave.ssh.host = node['ip']

        slave.vm.synced_folder ".", "/vagrant", disabled: true
      end
    end
  end
end
