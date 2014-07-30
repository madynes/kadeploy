class kabootstrap::params {
  $server_ip              = '10.0.10.253'
  $dns_domain             = 'testbed.lan'
  $dns_forward            = '10.0.2.3'
  $network_ip             = '10.0.10.0'
  $network_mask           = '255.255.255.0'
  $network_interface      = 'eth0'
  $nat_interface          = undef
  $pxe_bootstrap_method   = 'PXElinux'
  $pxe_bootstrap_program  = 'pxelinux.0'
  $pxe_profiles_directory = 'pxelinux.cfg'
  $pxe_chainload_program  = undef
  $pxe_kernel_vmlinuz     = undef
  $pxe_kernel_initrd      = undef
  $pxe_boot_method        = 'local'
  $nodes                  = {
                              'node-1' => {
                                'ip' => '10.0.10.1',
                                'mac' => '02:00:02:00:02:01',
                              }
                            }
  $mysql_db_name          = 'deploy3'
  $mysql_db_user          = 'deploy'
  $mysql_db_password      = 'passwd'
  $mysql_root_password    = 'root'
  $http_proxy             = undef
  $install_kind           = 'sources'
  $sources_directory      = undef
  $repository_url         = undef
  $packages_directory     = 'puppet:///modules/kabootstrap/packages'
  $vm_scripts             = false

  case $::osfamily {
    redhat: {
      $bind_conf = '/etc/named.conf'
      $bind_dir = '/var/named'
      $pkg_name = 'kadeploy-server'
      $pkg_deps = ['ruby','ruby-mysql','ruby-json','openssh-clients']
      $pkg_install = 'rpm -iv'
      $pkg_ext = 'rpm'
      $inst_deps = ['rubygem-rake', 'help2man', 'texlive-latex']
      $build_deps = ['git','rpm-build']
      $build_distro = 'redhat'
      $build_method = 'rpm'
      $build_pkg_base = 'build'
      $build_pkg_files = "RPMS/**/*.${pkg_ext}"
    }
    debian: {
      $bind_conf = '/etc/bind/named.conf'
      $bind_dir = '/etc/bind'
      $pkg_name = 'kadeploy'
      $pkg_deps = ['ruby1.9.1','ruby-mysql','ssh','taktuk']
      $pkg_install = 'dpkg --force-confdef --force-confold -i'
      $pkg_ext = 'deb'
      $inst_deps = ['rake', 'help2man', 'texlive-latex-base','texlive-latex-recommended','texlive-latex-extra']
      $build_deps = ['git','debhelper','gem2deb','git-buildpackage']
      $build_distro = 'debian'
      $build_method = 'deb'
      $build_pkg_base = 'source'
      $build_pkg_files = "../*.${pkg_ext}"
    }
    default: { fail("Unrecognized operating system") }
  }
}
