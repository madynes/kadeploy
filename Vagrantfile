Vagrant.configure("2") do |config|
  config.vm.boot_timeout = 50

  config.vm.define :kadeploy do |master|
    # Could be replaced by standard images (ie. chef/debian-7.4)
    #   https://github.com/opscode/bento
    #   https://vagrantcloud.com/discover/featured
    master.vm.box = 'irisa_debian-7.3.0_puppet'
    master.vm.box_url = 'https://vagrant.irisa.fr/boxes/irisa_debian-7.3.0_puppet-3.4.2.box'

    master.vm.network :private_network, ip: '10.0.10.10'
    config.vm.provider :virtualbox do |vb|
      vb.customize ["modifyvm", :id, "--memory", "1024"]
      vb.customize ["modifyvm", :id, "--nic1", "nat"]
      vb.customize ["modifyvm", :id, "--nic2", "hostonly"]
      vb.customize ["modifyvm", :id, "--hostonlyadapter2", "vboxnet0"]
    end
    master.vm.provision :puppet do |puppet|
      puppet.manifests_path = 'addons/puppet4vagranttb/manifests'
      puppet.manifest_file = 'init.pp'
      puppet.module_path = 'addons/puppet4vagranttb/modules'
#      puppet.options = "--verbose --debug"
    end
  end


  cluster_size = ENV['CLUSTER_SIZE'] || 1

  cluster_size.to_i.times do |i|
    id = i + 1
    mac = "00093d0011" + "%02x" % id
    name = "kadeploy_slave#{id}"
    ip = "10.0.10.#{10 + id}"
    config.vm.define name do |slave|
      slave.vm.box = 'irisa_debian-7.3.0_puppet'
      slave.vm.box_url = 'https://vagrant.irisa.fr/boxes/irisa_debian-7.3.0_puppet-3.4.2.box'
      config.vm.provider :virtualbox do |vb|
        vb.customize ["modifyvm", :id, "--memory", "384"]
        vb.customize ["modifyvm", :id, "--boot1", "net"]
        vb.customize ["modifyvm", :id, "--macaddress1", mac]
        vb.customize ["modifyvm", :id, "--nic1", "hostonly"]
        vb.customize ["modifyvm", :id, "--hostonlyadapter1", "vboxnet0"]
        vb.customize ["modifyvm", :id, "--nic2", "none"]
      end
      slave.ssh.host = ip
    end
  end
end
