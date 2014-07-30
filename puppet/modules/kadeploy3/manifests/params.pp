class kadeploy3::params {
  $install                = true
  $install_kastafior      = true
  $install_kascade        = true
  $create_user            = true
  $dns_name               = 'kadeploy.testbed.lan'
  $tftp_user              = 'tftp'
  $tftp_package           = 'tftpd-hpa'
  $pxe_repository         = '/var/lib/tftpboot'
  $pxe_export             = 'tftp'
  $pxe_bootstrap_method   = 'PXElinux'
  $pxe_bootstrap_program  = 'pxelinux.0'
  $pxe_profiles_directory = 'pxelinux.cfg'
  $pxe_profiles_naming    = 'ip_hex'
  $pxe_userfiles          = 'userfiles'
  $pxe_kernel_vmlinuz     = undef
  $pxe_kernel_initrd      = undef
  $mysql_db_host          = undef
  $mysql_db_name          = 'deploy3'
  $mysql_db_user          = undef
  $mysql_db_password      = undef
  $nodes                  = {
                              'node-1' => {
                                'ip' => '10.0.10.1',
                                'mac' => '02:00:02:00:02:01',
                              }
                            }
  $port                   = 25300
  $secure                 = false
  $ssh_connector          = 'ssh -A -l root -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=publickey -o BatchMode=yes'
  $remoteops              = {
                              'console' => {
                                'soft' => "SSH_CONNECTOR HOSTNAME_FQDN",
                              },
                              'reboot' => {
                                'soft' => "SSH_CONNECTOR HOSTNAME_FQDN /sbin/reboot",
                              }
                            }
  $service_name           = 'kadeploy'

  case $::osfamily {
    redhat: {
      $package_name = 'kadeploy-server'
      $package_doc_dir = '/usr/share/doc/kadeploy3'
      $package_scripts_dir = "${package_doc_dir}/scripts"
      $bootloader_scripts_dir = $package_scripts_dir
      $partitioning_scripts_dir = $package_scripts_dir
    }
    debian: {
      $package_name = 'kadeploy'
      $package_doc_dir = '/usr/share/doc/kadeploy'
      $package_scripts_dir = "${$package_doc_dir}/examples/scripts"
      $bootloader_scripts_dir = "${package_scripts_dir}/bootloader"
      $partitioning_scripts_dir = "${package_scripts_dir}/partitioning"
    }
  }
}
