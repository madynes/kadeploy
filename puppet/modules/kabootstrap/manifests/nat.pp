class kabootstrap::nat (
  $network_ip        = '10.0.10.0',
  $network_mask      = '255.255.255.0',
  $network_interface = 'eth0',
  $nat_interface     = undef,
) {
  if $nat_interface {
    exec {"/sbin/sysctl -w net.ipv4.ip_forward=1": }

    firewall { '100 masquerade':
      table    => 'nat',
      chain    => 'POSTROUTING',
      jump     => 'MASQUERADE',
      proto    => 'all',
      source   => "${network_ip}/${network_nask}",
      outiface => $nat_interface,
    }

    firewall { '110 nat_to_net':
      chain    => 'FORWARD',
      action   => 'accept',
      proto    => 'all',
      ctstate  => ['RELATED', 'ESTABLISHED'],
      iniface  => $nat_interface,
      outiface => $network_interface,
    }

    firewall { '110 net_to_nat':
      chain    => 'FORWARD',
      action   => 'accept',
      proto    => 'all',
      iniface  => $network_interface,
      outiface => $nat_interface,
    }
  }
}
