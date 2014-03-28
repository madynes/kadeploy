class kabootstrap::kadeploy::packages {
  class {'::kabootstrap::kadeploy::deps':
    kind => 'package',
    http_proxy => $::kaboostrap::kadeploy::http_proxy,
  }

  $pkg_dir = '/tmp/kadeploy-pkg'
  file {$pkg_dir:
    ensure  => directory,
    recurse => true,
    purge   => true,
    source  => $::kabootstrap::kadeploy::packages_directory,
  }

  exec {"pkg install":
    command => "${::kabootstrap::params::pkg_install} *.${::kabootstrap::params::pkg_ext}",
    path    => ['/bin','/sbin','/usr/bin/','/usr/sbin'],
    cwd     => $pkg_dir,
    user    => 'root',
    require => [Class['deps'],File[$pkg_dir]],
  }
}
