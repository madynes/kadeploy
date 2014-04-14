class {'kabootstrap':
  network_interface     => 'eth1',
  nat_interface         => 'eth0',
  pxe_chainload_program => 'chain.c32',
  pxe_kernel_vmlinuz    => 'vmlinuz-3.2.0-4-amd64',
  pxe_kernel_initrd     => 'initrd-3.2.0-4-amd64',
  sources_directory     => '/vagrant',
  install_kind          => 'repository',
  vm_scripts            => true,
}
