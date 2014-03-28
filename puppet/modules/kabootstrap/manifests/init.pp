class kabootstrap (
  $server_ip              = $::kabootstrap::params::server_ip,
  $dns_domain             = $::kabootstrap::params::dns_domain,
  $dns_forward            = $::kabootstrap::params::dns_forward,
  $network_ip             = $::kabootstrap::params::network_ip,
  $network_mask           = $::kabootstrap::params::network_mask,
  $network_interface      = $::kabootstrap::params::network_interface,
  $nat_interface          = $::kabootstrap::params::nat_interface,
  $pxe_bootstrap_program  = $::kabootstrap::params::pxe_bootstrap_program,
  $pxe_profiles_directory = $::kabootstrap::params::pxe_profiles_directory,
  $pxe_chainload_program  = $::kabootstrap::params::pxe_chainload_program,
  $pxe_kernel_vmlinuz     = $::kabootstrap::params::pxe_kernel_vmlinuz,
  $pxe_kernel_initrd      = $::kabootstrap::params::pxe_kernel_initrd,
  $pxe_boot_method        = $::kabootstrap::params::pxe_boot_method,
  $nodes                  = $::kabootstrap::params::nodes,
  $mysql_db_name          = $::kabootstrap::params::mysql_db_name,
  $mysql_db_user          = $::kabootstrap::params::mysql_db_user,
  $mysql_db_password      = $::kabootstrap::params::mysql_db_password,
  $mysql_root_password    = $::kabootstrap::params::mysql_root_password,
  $http_proxy             = $::kabootstrap::params::http_proxy,
  $install_kind           = $::kabootstrap::params::install_kind,
  $sources_directory      = $::kabootstrap::params::sources_directory,
  $repository_url         = $::kabootstrap::params::repository_url,
  $packages_directory     = $::kabootstrap::params::packages_directory,
) inherits kabootstrap::params {
  # Check data structures
  unless is_ip_address($network_ip) {
    fail "invalid ip address \"$network_ip\""
  }
  unless is_ip_address($network_mask) {
    fail "invalid netmask address \"$network_mask\""
  }
  unless is_ip_address($server_ip) {
    fail "invalid gateway address \"$server_ip\""
  }
  validate_hash($nodes)

  if $http_proxy == undef and $facter_http_proxy != undef {
    $http_proxy = $facter_http_proxy
  }

  # Configure NAT
  class {'kabootstrap::nat':
    network_ip        => $network_ip,
    network_mask      => $network_mask,
    network_interface => $network_interface,
    nat_interface     => $nat_interface,
  }

  # Configure DNS stack
  class {'kabootstrap::dns':
    network_ip  => $network_ip,
    server_ip   => $server_ip,
    nodes       => $nodes,
    dns_domain  => $dns_domain,
    dns_forward => $dns_forward,
  }

  # Configure DHCP stack
  class {'kabootstrap::dhcp':
    network_ip            => $network_ip,
    network_mask          => $network_mask,
    network_interface     => $network_interface,
    server_ip             => $server_ip,
    dns_domain            => $dns_domain,
    nodes                 => $nodes,
    pxe_bootstrap_program => $pxe_bootstrap_program,
  }

  # Configure PXE netboot stack (TFTP)
  class {'kabootstrap::tftp':
    pxe_bootstrap_program  => $pxe_bootstrap_program,
    pxe_profiles_directory => $pxe_profiles_directory,
    pxe_chainload_program  => $pxe_chainload_program,
    pxe_kernel_vmlinuz     => $pxe_kernel_vmlinuz,
    pxe_kernel_initrd      => $pxe_kernel_initrd,
    pxe_boot_method        => $pxe_boot_method,
  }
  Class['kabootstrap::tftp'] -> Class['kabootstrap::dhcp']

  # Configure SQL
  class {'kabootstrap::sql':
    dns_domain          => $dns_domain,
    mysql_db_name       => $mysql_db_name,
    mysql_db_user       => $mysql_db_user,
    mysql_db_password   => $mysql_db_password,
    mysql_root_password => $mysql_root_password,
  }

  # Kadeploy3
  class {'kabootstrap::kadeploy':
    install_kind       => $install_kind,
    sources_directory  => $sources_directory,
    repository_url     => $repository_url,
    packages_directory => $packages_directory,
    http_proxy         => $http_proxy,
  }
  Class['kabootstrap::dns']      -> Class['kabootstrap::kadeploy']
  Class['kabootstrap::tftp']     -> Class['kabootstrap::kadeploy']
  Class['kabootstrap::sql']      -> Class['kabootstrap::kadeploy']
}
