class kabootstrap::kadeploy (
  $install_kind       = 'sources',
  $sources_directory  = undef,
  $repository_url     = undef,
  $packages_directory = 'puppet:///modules/kabootstrap/packages',
  $tftp_user          = 'tftp',
  $tftp_package       = 'tftpd-hpa',
  $http_proxy         = undef,
) {
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

  case $install_kind {
    build: {
      include ::kabootstrap::kadeploy::build
      User['deploy'] -> Class['kabootstrap::kadeploy::build'] -> Class['kadeploy3']
    }
    sources: {
      include ::kabootstrap::kadeploy::sources
      User['deploy'] -> Class['kabootstrap::kadeploy::sources'] -> Class['kadeploy3']
    }
    packages: {
      include ::kabootstrap::kadeploy::packages
      User['deploy'] -> Class['kabootstrap::kadeploy::packages'] -> Class['kadeploy3']
    }
    repository: {
      include ::kabootstrap::kadeploy::repository
      User['deploy'] -> Class['kabootstrap::kadeploy::repository'] -> Class['kadeploy3']
    }
    default: { fail("Unrecognized install kind") }
  }
}
