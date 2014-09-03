class mock_karights {
  exec {'karights_mock_exec':
      command => "karights3 -a -m '*' -p '*' -u vagrant",
      path => ['/usr/bin', '/usr/sbin'],
      require => Service['kadeploy'];
  }
}
