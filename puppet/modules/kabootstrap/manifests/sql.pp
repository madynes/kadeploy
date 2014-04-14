class kabootstrap::sql (
  $dns_domain          = 'testbed.lan',
  $mysql_db_name       = 'deploy3',
  $mysql_db_user       = 'deploy',
  $mysql_db_password   = 'passwd',
  $mysql_root_password = 'root',
) {
  class { 'mysql::server':
    root_password => $mysql_root_password,
  }

  file { '/tmp/kadeploy.sql':
    path   => '/tmp/kadeploy.sql',
    ensure => file,
    links  => follow,
    source => 'puppet:///modules/kabootstrap/db_creation.sql',
  }

  mysql::db { $mysql_db_name:
    user     => $mysql_db_user,
    password => $mysql_db_password,
    host     => 'localhost',
    grant    => ['ALL'],
    charset  => 'utf8',
    collate  => 'utf8_general_ci',
    sql      => '/tmp/kadeploy.sql',
    require  => File['/tmp/kadeploy.sql'],
  }

  # Seems to be done by mysql::db
  #
  # mysql_user { "${mysql_db_user}@localhost":
  #   ensure => 'present',
  # }
  # mysql_grant { "${mysql_db_user}@localhost/${mysql_db_name}.*":
  #   ensure     => 'present',
  #   options    => ['GRANT'],
  #   privileges => ['ALL'],
  #   table      => "${mysql_db_name}.*",
  #   user       => "${mysql_db_user}@localhost",
  # }

  mysql_grant { "${mysql_db_user}@${dns_domain}/${mysql_db_name}.*":
    ensure => 'present',
    options    => ['GRANT'],
    privileges => ['ALL'],
    table      => "${mysql_db_name}.*",
    user       => "${mysql_db_user}@${dns_domain}",
  }
}
