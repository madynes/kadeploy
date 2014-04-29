class kabootstrap::dns (
  $network_ip  = '10.0.10.0',
  $server_ip   = '10.0.10.253',
  $nodes       = {
                   'node-1' => {
                     'ip' => '10.0.10.1',
                     'mac' => '02:00:02:00:02:01',
                   },
                 },
  $dns_domain  = 'testbed.lan',
  $dns_forward = '10.0.2.3',
) {
  include 'bind'

  # Will not work for networks with more than 253 nodes
  $reverse = join(delete_at(reverse(split($network_ip,'\.')),0),'.')
  $dns_reverse = "${reverse}.in-addr.arpa"

  bind::server::conf {$::kabootstrap::params::bind_conf:
    directory          => $::kabootstrap::params::bind_dir,
    listen_on_addr     => [ $server_ip, '127.0.0.1' ],
    listen_on_v6_addr  => [ 'none' ],
    forwarders         => [ $dns_forward ],
    allow_query        => [ 'localnets' ],
    recursion          => 'no',
    dnssec_enable      => 'no',
    dnssec_validation  => 'no',
    dnssec_lookaside   => 'no', # see https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=650030
    memstatistics_file => false,
    statistics_file    => false,
    dump_file          => false,
    zones              => {
      "$dns_domain"  => [
        'type master',
        "file \"db.${dns_domain}\"",
      ],
      "$dns_reverse" => [
        'type master',
        "file \"db.${reverse}\"",
      ],
    },
  }

  bind::server::file {"db.${dns_domain}":
    ensure  => present,
    zonedir => $::kabootstrap::params::bind_dir,
    content => template("kabootstrap/db.${dns_domain}.erb"),
  }

  bind::server::file {"db.${reverse}":
    ensure  => present,
    zonedir => $::kabootstrap::params::bind_dir,
    content => template("kabootstrap/db.${reverse}.erb"),
  }

  file { "/etc/resolv.conf":
    owner   => 'root',
    group   => 'root',
    mode    => 644,
    content => template("kabootstrap/resolv.conf.erb"),
    require => Service[$::bind::params::servicename],
  }

  # Ugly hack since the thias/bind receipe is not fully debian compatible
  # (the issue comes from the recursion parameter that enables other features)
  exec {"sed -i 's/recursion \+no/recursion yes/' $::kabootstrap::params::bind_conf":
    path    => ['/bin','/usr/bin/','/usr/local/bin'],
    onlyif  => "grep 'recursion \+no *;' $::kabootstrap::params::bind_conf",
    require => File[$::kabootstrap::params::bind_conf],
    notify  => Service[$::bind::params::servicename],
  }
}
