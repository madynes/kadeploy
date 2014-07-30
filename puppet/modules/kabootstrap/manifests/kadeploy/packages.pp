class kabootstrap::kadeploy::packages {
  class {'::kabootstrap::kadeploy::deps':
    kind => 'package',
    http_proxy => $::kabootstrap::http_proxy,
  }

  $pkg_dir = '/tmp/kadeploy-pkg'
  file {$pkg_dir:
    ensure  => directory,
    recurse => true,
    purge   => true,
    source  => $::kabootstrap::kadeploy::packages_directory,
  }

  package {$::kabootstrap::params::pkg_name:
    ensure => absent,
  }
  package {'kadeploy-client':
    ensure  => absent,
  }
  package {'kadeploy-common':
    ensure => absent,
    require => [Package[$::kabootstrap::params::pkg_name],Package['kadeploy-client']],
  }

  exec {"pkg install":
    command => "${::kabootstrap::params::pkg_install} *.${::kabootstrap::params::pkg_ext}",
    path    => ['/bin','/sbin','/usr/bin/','/usr/sbin'],
    cwd     => $pkg_dir,
    user    => 'root',
    require => [Class['kabootstrap::kadeploy::deps'],File[$pkg_dir],Package['kadeploy-common']],
  }
}
