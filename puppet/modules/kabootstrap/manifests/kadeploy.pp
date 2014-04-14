class kabootstrap::kadeploy (
  $install_kind       = 'sources',
  $sources_directory  = undef,
  $repository_url     = undef,
  $packages_directory = 'puppet:///modules/kabootstrap/packages',
  $http_proxy         = undef,
) {
  case $install_kind {
    build: {
      include ::kabootstrap::kadeploy::build
      User['deploy'] -> Class['kabootstrap::kadeploy::build']
    }
    sources: {
      include ::kabootstrap::kadeploy::sources
      User['deploy'] -> Class['kabootstrap::kadeploy::sources']
    }
    packages: {
      include ::kabootstrap::kadeploy::packages
      User['deploy'] -> Class['kabootstrap::kadeploy::packages']
    }
    repository: {
      include ::kabootstrap::kadeploy::repository
      User['deploy'] -> Class['kabootstrap::kadeploy::repository']
    }
    default: { fail("Unrecognized install kind") }
  }
}
