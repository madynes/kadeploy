class kadeploy {
  exec {
    'kadeploy_install':
      command => "rake install",
      cwd => '/vagrant',
      path => ['/usr/bin','/bin'],
      require => [Package['rubygems'], Service['isc-dhcp-server'], Exec['create_kadeploy_db'], Service['tftpd-hpa']];
  }
  service {
    'kadeploy':
      ensure => running,
      require => [File['/etc/kadeploy3/server.conf'], File['/etc/kadeploy3/client.conf'], File['/etc/kadeploy3/sample-cluster.conf'], File['/etc/kadeploy3/clusters.conf'], File['/srv/tftp/userfiles'], File['/srv/tftp/kernels'], File['/srv/tftp/pxelinux.cfg']];
  }
  exec {
    'karights':
      command => "karights3 -a -m '*' -p '*' -u root",
      path => ['/usr/bin', '/usr/sbin'],
      require => Service['kadeploy'];
  }
  File {
    mode => 644,
    owner => root,
    group => root,
  }
  file {
    '/etc/kadeploy3/server.conf':
      ensure => file,
      source => 'puppet:///modules/kadeploy/server.conf',
      require => Exec['kadeploy_install'],
  }
  file {
    '/etc/kadeploy3/client.conf':
      ensure => file,
      source => 'puppet:///modules/kadeploy/client.conf',
      require => Exec['kadeploy_install'],
  }
  file {
    '/etc/kadeploy3/sample-cluster.conf':
      ensure => file,
      source => 'puppet:///modules/kadeploy/sample-cluster.conf',
      require => Exec['kadeploy_install'],
  }
  file {
    '/etc/kadeploy3/clusters.conf':
      ensure => file,
      source => 'puppet:///modules/kadeploy/clusters.conf',
      require => Exec['kadeploy_install'],
  }
}
