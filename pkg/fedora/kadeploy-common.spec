Name:           kadeploy-common
Version:        3
Release:        beta%{?dist}
Summary:        Common part of the Kadeploy deployment tool.
Group:          Development/Languages
License:        CeCILL V2
URL:            http://gforge.inria.fr/scm/?group_id=2026
BuildRoot:      %{_tmppath}/%{name}-%{version}-%{release}-root-%(%{__id_u} -n)
BuildArch:      noarch
Requires:       ruby ruby-mysql

%description
Kadeploy 3 is the next generation of the fast and scalable deployment system for cluster and grid computing. Kadeploy is the reconfiguration system used in Grid5000, allowing the users to deploy their own OS on their reserved nodes.

%prep
%build
%install
%check

%clean
rm -rf $RPM_BUILD_ROOT

%files
%defattr(0755,root,root,-)
%dir /etc
%dir /usr
%dir /usr/local
%defattr(0755,deploy,root,-)
%dir /etc/kadeploy3
%dir /usr/local/kadeploy3
%dir /usr/local/kadeploy3/src
%dir /usr/local/kadeploy3/db
%dir /usr/local/kadeploy3/test
%dir /usr/local/kadeploy3/src/contrib
%dir /usr/local/kadeploy3/src/lib
%dir /usr/local/kadeploy3/addons
%dir /usr/local/kadeploy3/addons/deploy_env_generation/debootstrap/scripts
%dir /usr/local/kadeploy3/addons/deploy_env_generation/debootstrap
%dir /usr/local/kadeploy3/addons/deploy_env_generation
/etc/kadeploy3/load_kadeploy_env
/usr/local/kadeploy3/test/blackbox_tests.rb
%defattr(0644,deploy,root,-)
/usr/local/kadeploy3/db/db_creation.sql
/usr/local/kadeploy3/src/kanodes.rb
/usr/local/kadeploy3/src/contrib/taktuk_wrapper.rb
/usr/local/kadeploy3/src/kaenv.rb
/usr/local/kadeploy3/src/kadeploy_client.rb
/usr/local/kadeploy3/src/kaconsole.rb
/usr/local/kadeploy3/src/kadeploy_server.rb
/usr/local/kadeploy3/src/kastat.rb
/usr/local/kadeploy3/src/karights.rb
/usr/local/kadeploy3/src/lib/environment.rb
/usr/local/kadeploy3/src/lib/cache.rb
/usr/local/kadeploy3/src/lib/stepdeployenv.rb
/usr/local/kadeploy3/src/lib/parallel_runner.rb
/usr/local/kadeploy3/src/lib/nodes.rb
/usr/local/kadeploy3/src/lib/db.rb
/usr/local/kadeploy3/src/lib/md5.rb
/usr/local/kadeploy3/src/lib/parallel_ops.rb
/usr/local/kadeploy3/src/lib/managers.rb
/usr/local/kadeploy3/src/lib/config.rb
/usr/local/kadeploy3/src/lib/process_management.rb
/usr/local/kadeploy3/src/lib/bittorrent.rb
/usr/local/kadeploy3/src/lib/stepbootnewenv.rb
/usr/local/kadeploy3/src/lib/debug.rb
/usr/local/kadeploy3/src/lib/pxe_ops.rb
/usr/local/kadeploy3/src/lib/checkrights.rb
/usr/local/kadeploy3/src/lib/microsteps.rb
/usr/local/kadeploy3/src/lib/stepbroadcastenv.rb
/usr/local/kadeploy3/src/kareboot.rb
/usr/local/kadeploy3/addons/deploy_env_generation/debootstrap/linuxrc
/usr/local/kadeploy3/addons/deploy_env_generation/debootstrap/make_kernel.sh
/usr/local/kadeploy3/addons/deploy_env_generation/debootstrap/make_debootstrap.sh
/usr/local/kadeploy3/addons/deploy_env_generation/debootstrap/scripts/install_grub2
/usr/local/kadeploy3/addons/deploy_env_generation/debootstrap/scripts/launch_transfert.sh
/usr/local/kadeploy3/addons/deploy_env_generation/debootstrap/scripts/filenode.sh
/usr/local/kadeploy3/addons/deploy_env_generation/debootstrap/scripts/run_reboot
/usr/local/kadeploy3/addons/deploy_env_generation/debootstrap/scripts/execute_background.sh
/usr/local/kadeploy3/addons/deploy_env_generation/debootstrap/scripts/build_chain.sh
/usr/local/kadeploy3/addons/deploy_env_generation/debootstrap/scripts/run_kexec
/usr/local/kadeploy3/addons/deploy_env_generation/debootstrap/scripts/reboot_detach
/usr/local/kadeploy3/addons/deploy_env_generation/debootstrap/scripts/bittorrent_detach
/usr/local/kadeploy3/addons/deploy_env_generation/debootstrap/scripts/install_grub
/usr/local/kadeploy3/addons/deploy_env_generation/debootstrap/scripts/kexec_detach
/usr/local/kadeploy3/addons/deploy_env_generation/debootstrap/scripts/wait_background.sh
/usr/local/kadeploy3/addons/deploy_env_generation/debootstrap/scripts/launch_background.sh
/usr/local/kadeploy3/addons/deploy_env_generation/debootstrap/scripts/run_bittorrent
/usr/local/kadeploy3/addons/deploy_env_generation/debootstrap/mkdev


%doc

%changelog
