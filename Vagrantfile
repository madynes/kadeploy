Vagrant.configure("2") do |config|
  config.vm.define :kadeploy_master do |master|
    master.vm.box = 'irisa_debian-7.3.0_puppet'
    master.vm.box_url = 'https://vagrant.irisa.fr/boxes/irisa_debian-7.3.0_puppet-3.4.2.box'
    master.vm.network :private_network, ip: '10.0.10.10'
    config.vm.provider :virtualbox do |vb|
      vb.customize ["modifyvm", :id, "--memory", "1024"]
    end
    master.vm.provision :puppet do |puppet|
      puppet.manifests_path = 'addons/puppet4vagranttb/manifests'
      puppet.manifest_file = 'init.pp'
      puppet.module_path = 'addons/puppet4vagranttb/modules'
#      puppet.options = "--verbose --debug"
    end
  end

  config.vm.define :kadeploy_slave1 do |slave1|
    slave1.vm.box = 'irisa_debian-7.3.0_puppet'
    slave1.vm.box_url = 'https://vagrant.irisa.fr/boxes/irisa_debian-7.3.0_puppet-3.4.2.box'
    config.vm.provider :virtualbox do |vb|
      vb.customize ["modifyvm", :id, "--boot1", "net"]
      vb.customize ["modifyvm", :id, "--macaddress1", "00093d001101"]
      vb.customize ["modifyvm", :id, "--nic1", "hostonly"]
      vb.customize ["modifyvm", :id, "--hostonlyadapter1", "vboxnet0"]
    end
    #ugly, but I don't know how to ask Vagran to do not wait the VM. Indeed, it's not supposed to reachable from host.
    slave1.vm.boot_timeout = 1
  end
end
