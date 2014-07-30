class kabootstrap::kadeploy::sources {
  class {'::kabootstrap::kadeploy::deps':
    kind => 'install',
    http_proxy => $::kabootstrap::http_proxy,
  }

  exec {'rake install':
    command => "rake install[,${::kabootstrap::params::build_distro}]",
    path    => ['/bin','/usr/bin/','/usr/local/bin'],
    cwd     => $::kabootstrap::kadeploy::sources_directory,
    user    => 'root',
    environment => ['HOME=/root'], # see https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=627171
    require => Class['kabootstrap::kadeploy::deps'],
  }
}
