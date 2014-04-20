class kabootstrap::kadeploy::build {
  class {'kabootstrap::kadeploy::deps':
    kind       => 'build',
    http_proxy => $::kabootstrap::kadeploy::http_proxy,
  }

  $src_dir = '/tmp/kadeploy-src'
  $build_dir = '/tmp/kadeploy-build'
  case $::kabootstrap::params::build_pkg_base {
    build: { $pkg_dir = "${build_dir}/${::kabootstrap::params::build_pkg_files}" }
    source: { $pkg_dir = "${src_dir}/${::kabootstrap::params::build_pkg_files}" }
    default: { fail('Invalid build base') }
  }

  # TODO: find a better way to do it
  file {$src_dir:
    ensure  => absent,
    purge   => true,
    recurse => true,
    force   => true,
    backup  => false,
  }
  exec {'cp sources':
    command => "cp -Rf $::kabootstrap::kadeploy::sources_directory $src_dir",
    path    => ['/bin','/usr/bin/','/usr/local/bin'],
    require => File[$src_dir],
  }
  exec {'git clean':
    command => "git clean -ffd",
    path    => ['/bin','/sbin','/usr/bin/','/usr/sbin'],
    cwd     => $src_dir,
    user    => 'root',
    require => Exec['cp sources'],
  }
  exec {'git reset':
    command => "git reset --hard",
    path    => ['/bin','/sbin','/usr/bin/','/usr/sbin'],
    cwd     => $src_dir,
    user    => 'root',
    require => Exec['git clean'],
  }

  exec {"rake pkg":
    command     => "rake ${::kabootstrap::params::build_method}[${build_dir}]",
    path        => ['/bin','/usr/bin/','/usr/local/bin'],
    cwd         => $src_dir,
    user        => 'root',
    environment => ['HOME=/root'], # see https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=627171
    require => [Class['kabootstrap::kadeploy::deps'],Exec['git reset']],
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
    command   => "${::kabootstrap::params::pkg_install} ${pkg_dir}",
    path      => ['/bin','/sbin','/usr/bin/','/usr/sbin'],
    user      => 'root',
    require   => [Exec['rake pkg'],Package['kadeploy-common']],
  }
}
