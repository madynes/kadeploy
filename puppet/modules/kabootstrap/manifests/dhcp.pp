class kabootstrap::dhcp (
  $network_ip            = '10.0.10.0',
  $network_mask          = '255.255.255.0',
  $network_interface     = 'eth0',
  $server_ip             = '10.0.10.253',
  $dns_domain            = 'testbed.lan',
  $nodes                  = {
                              'node-1' => {
                                'ip' => '10.0.10.1',
                                'mac' => '02:00:02:00:02:01',
                              },
                            },
  $pxe_bootstrap_program = 'pxelinux.0',
) {
  class {'::dhcp':
    nameservers => [$server_ip],
    dnsdomain   => [$dns_domain ],
    ntpservers  => ['us.pool.ntp.org'],
    interfaces  => [$network_interface],
    pxeserver   => $server_ip,
    pxefilename => $pxe_bootstrap_program,
  }
  #Class['dhcp'] -> Service[$::bind::params::servicename]

  dhcp::pool{$dns_domain:
    network => $network_ip,
    mask    => $network_mask,
    range   => ["$network_ip $server_ip"],
    gateway => $server_ip,
  }

  define dhcpnode($ip,$mac) {
    dhcp::host{ $name:
      ip => $ip,
      mac => $mac;
    }
  }
  create_resources(dhcpnode,$nodes)
}
