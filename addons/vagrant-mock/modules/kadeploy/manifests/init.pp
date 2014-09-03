class kadeploy {
  exec {
    'kadeploy_install':
      command => "rake install",
      cwd => '/vagrant',
      path => ['/usr/bin','/bin'],
      require => [
                  Package['rubygems'],
                  Package['rake'],
                  Package['help2man'],
                  Package['taktuk'],
                  Package['libtaktuk-perl'],
                  Package['oidentd'],
                  Package['rake'],
                  Exec['create_kadeploy_db'],
                  User['deploy'],
                 ];
  }

  package { [
              "rubygems",
              "rake",  
              "help2man",
              "taktuk",
              "libtaktuk-perl",
              "oidentd",
              ]:
      ensure => "installed"
  }
  group {'deploy':
      ensure => present,
  }
  user {'deploy':
      home => '/usr/lib/deploy',
      shell => '/bin/bash',
      provider   => 'useradd',
      managehome => true,
      ensure => present,
  }

  service {'kadeploy':
      ensure => running,
      require => [
                  File['/etc/kadeploy3/server.conf'],
                  File['/etc/kadeploy3/client.conf'],
                  File['/etc/kadeploy3/sample-cluster.conf'],
                  File['/etc/kadeploy3/clusters.conf'],
                  File['/etc/kadeploy3/command.conf'],
                  File['/etc/kadeploy3/keys/id_deploy'],
                  File['/etc/kadeploy3/ssl/test2.cert'],
                  File['/etc/kadeploy3/ssl/test2.key'],
                  File['/etc/kadeploy3/ssl/test.cert'],
                  File['/var/lib/deploy/tftp/pxelinux.cfg'],
                  File['/var/lib/deploy/tftp/userfiles'],
                  Class['mock']
              ];
  }
  exec {'karights':
      command => "karights3 -a -m '*' -p '*' -u root",
      path => ['/usr/bin', '/usr/sbin'],
      require => Service['kadeploy'];
  }
  File {
    mode => 644,
    owner => deploy,
    group => deploy,
  }
  file {'/etc/kadeploy3/server.conf':
      ensure => file,
      source => 'puppet:///modules/kadeploy/server.conf',
      require => Exec['kadeploy_install'],
  }
  file {'/etc/kadeploy3/client.conf':
      ensure => file,
      source => 'puppet:///modules/kadeploy/client.conf',
      require => Exec['kadeploy_install'],
  }
  file {'/etc/kadeploy3/sample-cluster.conf':
      ensure => file,
      source => 'puppet:///modules/kadeploy/sample-cluster.conf',
      require => Exec['kadeploy_install'],
  }
  file {'/etc/kadeploy3/clusters.conf':
      ensure => file,
      source => 'puppet:///modules/kadeploy/clusters.conf',
      require => Exec['kadeploy_install'],
  }
  file {'/etc/kadeploy3/command.conf':
      ensure => file,
      source => 'puppet:///modules/kadeploy/command.conf',
      require => Exec['kadeploy_install'],
  }
  file {'/etc/kadeploy3/keys':
      ensure => directory,
      require => Exec['kadeploy_install'],
  }
  file {'/etc/kadeploy3/keys/id_deploy':
      ensure => file,
      mode => 400,
      source => 'puppet:///modules/kadeploy/keys/id_deploy',
      require => File['/etc/kadeploy3/keys'],
  }



  file {'/etc/kadeploy3/ssl':
      ensure => directory,
      require => Exec['kadeploy_install'],
  }
  file {'/etc/kadeploy3/ssl/test.cert':
      ensure => file,
      source => 'puppet:///modules/kadeploy/ssl/test.cert',
      require => File['/etc/kadeploy3/ssl'],
  }
  file {'/etc/kadeploy3/ssl/test2.cert':
      ensure => file,
      source => 'puppet:///modules/kadeploy/ssl/test2.cert',
      require => File['/etc/kadeploy3/ssl'],
  }
  file {'/etc/kadeploy3/ssl/test2.key':
      ensure => file,
      mode => 400,
      source => 'puppet:///modules/kadeploy/ssl/test2.key',
      require => File['/etc/kadeploy3/ssl'],
  }
  file {'/etc/kadeploy3/envs':
      ensure => directory,
      require => Exec['kadeploy_install'],
  }
  file {'/etc/kadeploy3/envs/wheezy-min.dsc':
      ensure => file,
      source => 'puppet:///modules/kadeploy/wheezy-min.dsc',
      require => File['/etc/kadeploy3/envs'],
  }
  exec {'/etc/kadeploy3/envs/wheezy-x64-min-1.4.tgz':
      command => "wget -q http://kadeploy3.gforge.inria.fr/files/wheezy-x64-min-1.4.tgz",
      cwd => '/etc/kadeploy3/envs',
      path => '/usr/bin',
      require => File['/etc/kadeploy3/envs'],
  }
  exec { 'add_env':
      command => "kaenv3 -a /etc/kadeploy3/envs/wheezy-min.dsc",
      path => ['/bin', '/usr/bin'],
      require => [File['/etc/kadeploy3/envs/wheezy-min.dsc'], Exec['/etc/kadeploy3/envs/wheezy-x64-min-1.4.tgz'], Service['kadeploy']],
  }
}
