class dhcp {
  package {
    'isc-dhcp-server':
      ensure => installed,
      require => Exec['apt-get-update'];
  }
  service {
    'isc-dhcp-server':
      ensure => running,
      require => [Package['isc-dhcp-server'],File['/etc/default/isc-dhcp-server'],File['/etc/dhcp/dhcpd.conf']];
  }
  file {
    '/etc/default/isc-dhcp-server':
      ensure => file,
      mode => 644, owner => root, group => root,
      source => 'puppet:///modules/dhcp/isc-dhcp-server',
  }
  file {
    '/etc/dhcp/dhcpd.conf':
      ensure => file,
      mode => 644, owner => root, group => root,
      source => 'puppet:///modules/dhcp/dhcpd.conf',
  }
}
