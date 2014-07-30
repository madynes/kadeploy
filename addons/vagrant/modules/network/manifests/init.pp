class network {
  file {
    '/etc/network/interfaces':
      ensure => file,
      source => 'puppet:///modules/network/interfaces';
  }
}
