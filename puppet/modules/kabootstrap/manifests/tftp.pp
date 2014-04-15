class kabootstrap::tftp (
  $pxe_bootstrap_program  = 'pxelinux.0',
  $pxe_profiles_directory = 'pxelinux.cfg',
  $pxe_chainload_program  = undef,
  $pxe_kernel_vmlinuz     = undef,
  $pxe_kernel_initrd      = undef,
  $pxe_boot_method        = 'local',
) {
  class {'::tftp':
    inetd => false,
  }
  Package['tftpd-hpa'] -> Service['tftpd-hpa'] # receipe bugfix

  tftp::file { $pxe_bootstrap_program:
    source  => "puppet:///modules/kabootstrap/${pxe_bootstrap_program}",
  }

  if $pxe_chainload_program {
    tftp::file { $pxe_chainload_program:
      source  => "puppet:///modules/kabootstrap/${pxe_chainload_program}",
    }
  }

  if $pxe_kernel_vmlinuz {
    tftp::file { $pxe_kernel_vmlinuz:
      source  => "puppet:///modules/kabootstrap/${pxe_kernel_vmlinuz}",
    }
  }

  if $pxe_kernel_initrd {
    tftp::file { $pxe_kernel_initrd:
      source  => "puppet:///modules/kabootstrap/${pxe_kernel_initrd}",
    }
  }

  tftp::file { $pxe_profiles_directory:
    ensure => directory,
    mode   => 775,
  }

  tftp::file { "${pxe_profiles_directory}/default":
    ensure => file,
    content => template('kabootstrap/default_pxe_profile'),
  }
}
