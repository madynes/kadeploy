class mysql {
  package {
    'mysql-server':
      ensure => installed;
  }
  package {
    'libmysql-ruby':
      ensure => installed;
  }
  service {
    'mysql':
      ensure => running;
  }
  $dbscript = '/tmp/create_dh.sh'
  file {
    $dbscript:
      source => 'puppet:///modules/mysql/create_db.sh',
      mode => '0700';
  }
  exec {
    'create_kadeploy_db':
      command => "/bin/bash $dbscript",
  }
  Package['mysql-server'] -> Service['mysql'] -> File[$dbscript] -> Exec['create_kadeploy_db']
}
