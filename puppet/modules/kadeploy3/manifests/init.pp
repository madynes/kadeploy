class kadeploy3 (
  $install                = $::kadeploy3::params::install,
  $install_kastafior      = $::kadeploy3::params::install_kastafior,
  $install_kascade        = $::kadeploy3::params::install_kascade,
  $create_user            = $::kadeploy3::params::create_user,
  $package_doc_dir        = $::kadeploy3::params::package_doc_dir,
  $package_scripts_dir    = $::kadeploy3::params::package_scripts_dir,
  $dns_name               = $::kadeploy3::params::dns_name,
  $tftp_user              = $::kadeploy3::params::tftp_user,
  $tftp_package           = $::kadeploy3::params::tftp_package,
  $pxe_repository         = $::kadeploy3::params::pxe_repository,
  $pxe_export             = $::kadeploy3::params::pxe_export,
  $pxe_bootstrap_method   = $::kadeploy3::params::pxe_bootstrap_method,
  $pxe_bootstrap_program  = $::kadeploy3::params::pxe_bootstrap_program,
  $pxe_profiles_directory = $::kadeploy3::params::pxe_profiles_directory,
  $pxe_profiles_naming    = $::kadeploy3::params::pxe_profiles_naming,
  $pxe_userfiles          = $::kadeploy3::params::pxe_userfiles,
  $pxe_kernel_vmlinuz     = $::kadeploy3::params::pxe_kernel_vmlinuz,
  $pxe_kernel_initrd      = $::kadeploy3::params::pxe_kernel_initrd,
  $mysql_db_host          = $::kadeploy3::params::mysql_db_host,
  $mysql_db_name          = $::kadeploy3::params::mysql_db_name,
  $mysql_db_user          = $::kadeploy3::params::mysql_db_user,
  $mysql_db_password      = $::kadeploy3::params::mysql_db_password,
  $nodes                  = $::kadeploy3::params::nodes,
  $port                   = $::kadeploy3::params::port,
  $secure                 = $::kadeploy3::params::secure,
  $ssh_connector          = $::kadeploy3::params::ssh_connector,
  $remoteops              = $::kadeploy3::params::remoteops,
) inherits kadeploy3::params {
  validate_hash($nodes)
  validate_hash($remoteops)

  if $mysql_db_host == undef {
    fail("MySQL database host is not specified")
  }
  if $mysql_db_user == undef {
    fail("MySQL database user is not specified")
  }
  if $mysql_db_password == undef {
    fail("MySQL database password is not specified")
  }
  if $pxe_kernel_vmlinuz == undef {
    fail("No deployment kernel vmlinuz is specified")
  }
  if $pxe_kernel_initrd == undef {
    fail("No deployment kernel initrd is specified")
  }

  if $create_user == true {
    group{'deploy':
      ensure => present,
      system => true,
    }
    user{'deploy':
      ensure  => present,
      system  => true,
      home    => '/var/lib/deploy',
      gid     => 'deploy',
      groups  => [$tftp_user],
      require => [Group['deploy'],Package[$tftp_package]],
    }
  }

  service {$service_name:
    ensure => running,
  }

  file {'/etc/kadeploy3':
    mode    => 755,
    owner   => 'deploy',
    group   => 'deploy',
    ensure  => directory,
    require => [User['deploy'],Group['deploy']],
  }

  if $install == true {
    package {$package_name:
      ensure => installed,
    }
    Package[$package_name] -> Service[$service_name]
    Package[$package_name] -> File['/etc/kadeploy3']
  }

  file {'/etc/kadeploy3/keys':
    mode    => 755,
    owner   => 'deploy',
    group   => 'deploy',
    ensure  => directory,
    require => [User['deploy'],Group['deploy'],File['/etc/kadeploy3']],
    notify  => Service[$service_name],
  }

  file {'/etc/kadeploy3/keys/id_deploy':
    mode    => 600,
    owner   => 'deploy',
    group   => 'deploy',
    source  => 'puppet:///modules/kadeploy3/id_deploy',
    ensure  => present,
    require => [User['deploy'],Group['deploy'],File['/etc/kadeploy3/keys']],
    notify  => Service[$service_name],
  }

  file {'/etc/kadeploy3/keys/id_deploy.pub':
    mode    => 600,
    owner   => 'deploy',
    group   => 'deploy',
    source  => 'puppet:///modules/kadeploy3/id_deploy.pub',
    ensure  => present,
    require => [User['deploy'],Group['deploy'],File['/etc/kadeploy3/keys']],
    notify  => Service[$service_name],
  }

  file {'/etc/kadeploy3/server.conf':
    mode    => 644,
    owner   => 'deploy',
    group   => 'deploy',
    content => template('kadeploy3/server.conf.erb'),
    ensure  => present,
    require => [User['deploy'],Group['deploy'],File['/etc/kadeploy3']],
    notify  => Service[$service_name],
  }

  file {'/etc/kadeploy3/clusters.conf':
    mode    => 644,
    owner   => 'deploy',
    group   => 'deploy',
    content => template('kadeploy3/clusters.conf.erb'),
    ensure  => present,
    require => [User['deploy'],Group['deploy'],File['/etc/kadeploy3']],
    notify  => Service[$service_name],
  }

  file {'/etc/kadeploy3/sample-cluster.conf':
    mode    => 644,
    owner   => 'deploy',
    group   => 'deploy',
    content => template('kadeploy3/sample-cluster.conf.erb'),
    ensure  => present,
    require => [User['deploy'],Group['deploy'],File['/etc/kadeploy3']],
    notify  => Service[$service_name],
  }

  file {'/etc/kadeploy3/command.conf':
    mode    => 644,
    owner   => 'deploy',
    group   => 'deploy',
    content => template('kadeploy3/command.conf.erb'),
    ensure  => present,
    require => [User['deploy'],Group['deploy'],File['/etc/kadeploy3']],
    notify  => Service[$service_name],
  }

  file {'/etc/kadeploy3/client.conf':
    mode    => 644,
    owner   => 'deploy',
    group   => 'deploy',
    content => template('kadeploy3/client.conf.erb'),
    ensure  => present,
    require => [User['deploy'],Group['deploy'],File['/etc/kadeploy3']],
    notify  => Service[$service_name],
  }

  #  file {'/etc/kadeploy3/install_grub2':
  #    mode    => 755,
  #    owner   => 'deploy',
  #    group   => 'deploy',
  #    ensure  => link,
  #    target  => "${package_scripts_dir}/bootloader/install_grub2",
  #    require => [User['deploy'],Group['deploy'],File['/etc/kadeploy3']],
  #  }
  #
  #  file {'/etc/kadeploy3/parted-sample':
  #    mode    => 755,
  #    owner   => 'deploy',
  #    group   => 'deploy',
  #    ensure  => link,
  #    target  => "${package_scripts_dir}/partitioning/parted-sample",
  #    require => [User['deploy'],Group['deploy'],File['/etc/kadeploy3']],
  #  }

  if $install_kastafior == true or $install_kascade == true {
    package {'gzip':
      ensure => present,
    }
  }

  if $install_kastafior == true {
    exec {'install kastafior':
      command   => "gzip -cd ${package_doc_dir}/kastafior.gz > /usr/bin/kastafior",
      user      => 'root',
      path      => ['/bin','/usr/bin','/usr/local/bin'],
      creates   => '/usr/bin/kastafior',
      logoutput => 'on_failure',
      require   => Package['gzip'],
    }

    file {'/usr/bin/kastafior':
      ensure  => present,
      mode    => 755,
      require => Exec['install kastafior'],
    }
  }

  if $install_kascade == true {
    exec {'install kascade':
      command   => "gzip -cd ${package_doc_dir}/kascade.gz > /usr/bin/kascade",
      user      => 'root',
      path      => ['/bin','/usr/bin','/usr/local/bin'],
      creates   => '/usr/bin/kascade',
      logoutput => 'on_failure',
      require   => Package['gzip'],
    }

    file {'/usr/bin/kascade':
      ensure => present,
      mode   => 755,
      require => Exec['install kascade'],
    }
  }

  file {"${pxe_repository}/${pxe_userfiles}":
    ensure => directory,
    mode   => 775,
    owner  => $tftp_user,
    group  => $tftp_user,
  }

  exec{'karights3 -o -a -u root; true':
    path    => ['/bin','/sbin','/usr/bin','/usr/sbin','/usr/local/bin','/usr/local,sbin'],
    require => [Service[$service_name],File['/etc/kadeploy3/client.conf']],
  }
}
