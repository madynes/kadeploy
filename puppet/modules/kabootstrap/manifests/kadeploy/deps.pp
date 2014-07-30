class kabootstrap::kadeploy::deps (
  $kind = 'package',
  $http_proxy = undef,
) {
  include ::kabootstrap::params

  case $kind{
    package: {
      $pkgs = $::kabootstrap::params::pkg_deps
    }
    install: {
      $pkgs = [
        $::kabootstrap::params::pkg_deps,
        $::kabootstrap::params::inst_deps,
      ]
    }
    build: {
      $pkgs = [
        $::kabootstrap::params::pkg_deps,
        $::kabootstrap::params::inst_deps,
        $::kabootstrap::params::build_deps
      ]
    }
    default: { fail("Unrecognized dependency") }
  }

  # Setup custom repositories
  case $::osfamily {
    redhat: {
      if $::lsbmajdistrelease < 5 {
        fail('Uncompatible OS version for EPEL')
      }

      yumrepo {'EPEL':
        descr    => "Fedora Extra Packages for Enterprise Linux (EPEL)",
        baseurl  => "http://dl.fedoraproject.org/pub/epel/${::lsbmajdistrelease}/\$basearch/",
        proxy    => $http_proxy,
        enabled  => 1,
        gpgcheck => 0,
      }

      exec {'yum check-update; true':
        path    => ['/bin','/sbin/','/usr/bin','/usr/sbin'],
        user    => 'root',
        require => Yumrepo['EPEL'],
        before  => Package[$pkgs],
      }
    }
  }

  package {$pkgs:
    ensure => installed,
  }
}
