class mock {
  user { "mock":
      ensure => present,
      home => '/home/mock',
      shell => '/bin/mocksh',
      provider   => 'useradd',
      purge_ssh_keys => true,
      managehome => true,
      require => File["/bin/mocksh"],
  }
  ssh_authorized_key { "mock":
    ensure => "present",
    type => "ssh-rsa",
    key => "AAAAB3NzaC1yc2EAAAADAQABAAABAQDWyJKQ0H6bCWejOcUcWiCVf6UvpIVwPlCGSY+8U9XxSsrzkfoYl2rKs+WCk6xykblKjRSEk2p69gJo8Z3QUxWisashbd8yM52+wUbjl11N39ABMNrO7MVlOOaCVCeuRbWtvLVwACPAy4Rz5Rj8+L8dokoGn/FtWD3TJHNERrDzJl71BKqIIM9jNaG6d5ell9K8+cK/57tn/6s0Xh92TijxIyCx5Z8AC6K67FVhadB2iTtiCmbJRhfMFzoWOzYpFqpdQyJDH+5diSPnsQrjDV9vr9C+QmIC9os/33eBAjkjjSRg6aeYosgwuGujeAJZRR7ZictvBKqWLq2+hg3NjIcH",
    user => "mock",
  }
  ssh_authorized_key { "root":
    ensure => "present",
    type => "ssh-rsa",
    key => "AAAAB3NzaC1yc2EAAAADAQABAAABAQDWyJKQ0H6bCWejOcUcWiCVf6UvpIVwPlCGSY+8U9XxSsrzkfoYl2rKs+WCk6xykblKjRSEk2p69gJo8Z3QUxWisashbd8yM52+wUbjl11N39ABMNrO7MVlOOaCVCeuRbWtvLVwACPAy4Rz5Rj8+L8dokoGn/FtWD3TJHNERrDzJl71BKqIIM9jNaG6d5ell9K8+cK/57tn/6s0Xh92TijxIyCx5Z8AC6K67FVhadB2iTtiCmbJRhfMFzoWOzYpFqpdQyJDH+5diSPnsQrjDV9vr9C+QmIC9os/33eBAjkjjSRg6aeYosgwuGujeAJZRR7ZictvBKqWLq2+hg3NjIcH",
    user => "root",
  }
  
  group { "mock":
      ensure => present,
  }

  User['mock'] ->  Exec['fake_kernel']

  $hostscript = '/tmp/set_hosts.sh'
  file { $hostscript:
      source => 'puppet:///modules/mock/set_hosts.sh',
      mode => '0700';
  }
  exec {'set_hosts':
      command => "/bin/bash $hostscript",
  }

  file { [
          '/var/lib/deploy',
          '/var/lib/deploy/tftp',
          '/var/lib/deploy/tftp/pxelinux.cfg',
          '/var/lib/deploy/tftp/userfiles',
          '/var/lib/deploy/bin'
         ]:

     ensure => 'directory',
     owner => deploy,
     group => deploy,
     require => Exec['kadeploy_install'],
  }


  file {'/home/mock/bin':
    ensure => 'directory',
    owner => mock,
    group => mock,
  }

  file { "/usr/bin/dooropenclose":
    ensure => present,
    mode => 0755,
    owner => root,
    group => root,
    source => "puppet:///modules/mock/bin/dooropenclose"
  }

  file { "/usr/bin/kalogger":
    ensure => present,
    mode => 0755,
    owner => root,
    group => root,
    source => "puppet:///modules/mock/bin/kalogger"
  }

  file { "/usr/bin/karesetnodes":
    ensure => present,
    mode => 0755,
    owner => root,
    group => root,
    source => "puppet:///modules/mock/bin/karesetnodes"
  }

  file { "/bin/mocksh":
    ensure => present,
    mode => 0755,
    owner => root,
    group => root,
    source => "puppet:///modules/mock/bin/mocksh"
  }

  file { "/usr/bin/kamorespeed":
    ensure => present,
    mode => 0755,
    owner => root,
    group => root,
    source => "puppet:///modules/mock/bin/kamorespeed"
  }

  file { "/usr/bin/karelativePath":
    ensure => present,
    mode => 0755,
    owner => root,
    group => root,
    source => "puppet:///modules/mock/bin/karelativePath"
  }
  file { "/home/mock/.bashrc":
    ensure => present,
    mode => 0644,
    owner => mock,
    group => mock,
    source => "puppet:///modules/mock/mock/.bashrc"
  }
  file { "/home/mock/bin/umount":
    mode => 0755,
    ensure => "link",
    owner => root,
    group => root,
    target  => "/usr/bin/kalogger"
  }

  file { "/home/mock/bin/reboot":
    mode => 0755,
    ensure => "link",
    owner => root,
    group => root,
    target  => "/usr/bin/kalogger"
  }

  file { "/home/mock/bin/mkfs":
    mode => 0755,
    ensure => "link",
    owner => root,
    group => root,
    target  => "/usr/bin/kalogger"
  }

  file { "/home/mock/bin/mkswap":
    mode => 0755,
    ensure => "link",
    owner => root,
    group => root,
    target  => "/usr/bin/kalogger"
  }

  file { "/home/mock/bin/kexec":
    mode => 0755,
    ensure => "link",
    owner => root,
    group => root,
    target  => "/usr/bin/kalogger"
  }

  file { "/home/mock/bin/poweroff":
    mode => 0755,
    ensure => "link",
    owner => root,
    group => root,
    target  => "/usr/bin/kalogger"
  }

  file { "/home/mock/bin/install_grub2":
    mode => 0755,
    ensure => "link",
    owner => root,
    group => root,
    target  => "/usr/bin/kalogger"
  }

  file { "/home/mock/bin/mount":
    mode => 0755,
    ensure => "link",
    owner => root,
    group => root,
    target  => "/usr/bin/kalogger"
  }

  file { "/home/mock/bin/cat":
    mode => 0755,
    ensure => "link",
    owner => root,
    group => root,
    target  => "/usr/bin/kalogger"
  }

  file { "/sbin/kexec":
    mode => 0755,
    ensure => "link",
    owner => root,
    group => root,
    target  => "/usr/bin/kalogger"
  }

  file { "/var/lib/deploy/bin/install_grub2":
    require => Exec['kadeploy_install'],
    mode => 0755,
    ensure => "link",
    owner => root,
    group => root,
    target  => "/usr/bin/kalogger"
  }

  file { "/var/lib/deploy/bin/partition":
    require => Exec['kadeploy_install'],
    mode => 0755,
    ensure => "link",
    owner => deploy,
    group => deploy,
    target  => "/usr/bin/kalogger"
  }

  file { "/var/lib/deploy/bin/kastafior":
    require => Exec['kadeploy_install'],
    mode => 0755,
    ensure => "link",
    owner => deploy,
    group => deploy,
    target  => "/usr/bin/kalogger"
  }
  file { "/var/lib/deploy/bin/lanpower":
    require => Exec['kadeploy_install'],
    mode => 0755,
    ensure => "link",
    owner => deploy,
    group => deploy,
    target  => "/usr/bin/kalogger"
  }
  file { "/mnt/dest":
    ensure => 'directory',
    owner => 'root',
    group => 'root',
    mode => '0755',
  }
  file { "/mnt/dest/root":
    ensure => 'directory',
    owner => 'mock',
    group => 'root',
    mode => '0755',
    require => File['/mnt/dest'];
  }
  exec { fake_kernel:
    command => "bash -c 'touch /mnt/dest/{initrd.img,vmlinuz}'",
    path => "/bin/",
    require => File['/mnt/dest'];
  }

  # define the service to restart
  service { "ssh":
    ensure  => "running",
    enable  => "true",
    require => Package["openssh-server"],
  }
  package {"openssh-server":
    ensure => "installed"
  }

  file { '/etc/ssh/sshd_config':
    notify  => Service["ssh"],
    ensure => present,
    mode => 0744,
    owner => root,
    group => root,
    source => 'puppet:///modules/mock/sshd_config'
  }
}
