# Samples:
#   DEV=1 INSTALL=build vagrant up
#
# Configure/Tune the kabootstrap receipe: puppet/modules/kabootstrap/README

Vagrant.configure("2") do |config|
  config.vm.boot_timeout = 50
  install = (ENV['INSTALL'] || 'init').downcase
  install = 'init' unless install =~ /(packages|build|sources|repository)/

  config.vm.define :kadeploy do |master|
    if Vagrant::VERSION >= "1.5.0"
      master.vm.box = 'chef/debian-7.4'
    else
      master.vm.box = 'debian-7.4'
      master.vm.box_url =
        "https://vagrantcloud.com/chef/debian-7.4/version/1/provider/virtualbox.box"
    end

    master.vm.network :private_network, ip: '10.0.10.253'
    master.vm.provider :virtualbox do |vb|
      vb.customize ["modifyvm", :id, "--memory", "1024"]
      vb.customize ["modifyvm", :id, "--nic1", "nat"]
      vb.customize ["modifyvm", :id, "--nic2", "hostonly"]
      vb.customize ["modifyvm", :id, "--hostonlyadapter2", "vboxnet0"]
    end

    if ENV['http_proxy']
      master.vm.provision :shell, inline:
        "echo 'export http_proxy=#{ENV['http_proxy'].strip}' >> /etc/profile"
    end
    if ENV['https_proxy']
      master.vm.provision :shell, inline:
        "echo 'export https_proxy=#{ENV['https_proxy'].strip}' >> /etc/profile"
    end

    master.vm.provision :shell, path: 'addons/puppet4vagranttb/install_puppet.sh'

    master.vm.provision :puppet do |puppet|
      puppet.manifests_path = 'puppet/manifests'
      puppet.manifest_file = "#{install}.pp"
      puppet.module_path = 'puppet/modules'
      puppet.options = "--verbose --debug" if ENV['DEBUG']
    end

    if ENV['DEV'] # for development purpose
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
  end


  cluster_size = ENV['CLUSTER_SIZE'] || 1

  cluster_size.to_i.times do |i|
    id = i + 1
    mac = "0200020002" + "%02x" % id
    name = "node-#{id}"
    ip = "10.0.10.#{id + 1}"
    config.vm.define name do |slave|
      slave.vm.box = 'tcl'
      slave.vm.box_url = 'http://kadeploy3.gforge.inria.fr/files/tcl.box'

      slave.vm.provider :virtualbox do |vb|
        vb.customize ["modifyvm", :id, "--memory", "384"]
        vb.customize ["modifyvm", :id, "--boot1", "net"]
        vb.customize ["modifyvm", :id, "--macaddress1", mac]
        vb.customize ["modifyvm", :id, "--nic1", "hostonly"]
        vb.customize ["modifyvm", :id, "--nictype1", "82540EM"]
        vb.customize ["modifyvm", :id, "--hostonlyadapter1", "vboxnet0"]
        # Disable USB since it's not necessary and depends on extra modules
        vb.customize ["modifyvm", :id, "--usbehci", "off"]
        vb.customize ["modifyvm", :id, "--usb", "off"]
      end
      slave.ssh.host = ip

      slave.vm.synced_folder ".", "/vagrant", disabled: true
    end
  end
end
