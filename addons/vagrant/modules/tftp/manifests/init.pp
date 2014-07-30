class tftp {
  package {
    'syslinux':
      ensure => installed,
      require => Exec['apt-get-update'],
  }
  package {
    'tftpd-hpa':
      ensure => installed,
      require => Exec['apt-get-update'],
  }
  file {
    '/etc/default/tftpd-hpa':
      ensure => file,
      mode => 644, owner => root, group => root,
      source => 'puppet:///modules/tftp/tftpd-hpa',
      require => Package['tftpd-hpa'],
  }
  service {
    'tftpd-hpa':
      ensure => running,
      require => File['/etc/default/tftpd-hpa','/srv/tftp'],
  }
  file {
    ['/srv/tftp','/srv/tftp/kernels','/srv/tftp/pxelinux.cfg','/srv/tftp/userfiles']:
      ensure => directory,
      owner => deploy,
  }
  file {
    "/srv/tftp/pxelinux.cfg/default":
      ensure => file,
      source => 'puppet:///modules/tftp/default_profile',
      require => File['/srv/tftp/pxelinux.cfg'],
      mode => 644, owner => deploy, group => deploy,
  }
  file {
    '/srv/tftp/pxelinux.0':
      ensure => present,
      source => '/usr/lib/syslinux/pxelinux.0',
      require => Package['syslinux'],
  }
  file {
    '/srv/tftp/chain.c32':
      ensure => present,
      source => '/usr/lib/syslinux/chain.c32',
      require => Package['syslinux'],
  }
  file {
    '/srv/tftp/mboot.c32':
      ensure => present,
      source => '/usr/lib/syslinux/mboot.c32',
      require => Package['syslinux'],
  }
  exec {
    '/srv/tftp/kernels/vmlinuz-3.2.0-4-amd64':
      command => "wget -q http://kadeploy3.gforge.inria.fr/files/vmlinuz-3.2.0-4-amd64",
      cwd => '/srv/tftp/kernels',
      path => '/usr/bin',
      require => File['/srv/tftp/kernels'],
  }
  exec {
    '/srv/tftp/kernels/initrd-3.2.0-4-amd64':
      command => "wget -q http://kadeploy3.gforge.inria.fr/files/initrd-3.2.0-4-amd64",
      cwd => '/srv/tftp/kernels',
      path => '/usr/bin',
      require => File['/srv/tftp/kernels'],
  }
}
