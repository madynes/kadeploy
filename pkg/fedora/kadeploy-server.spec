Name:           kadeploy-server
Version:        3
Release:        beta%{?dist}
Summary:        Server part of the Kadeploy deployment tool.

Group:          Development/Languages

License:        CeCILL V2
URL:            http://gforge.inria.fr/scm/?group_id=2026
BuildRoot:      %{_tmppath}/%{name}-%{version}-%{release}-root-%(%{__id_u} -n)

BuildArch:      noarch
Requires:       ruby ruby-mysql kadeploy-common

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
%dir /usr/sbin
%defattr(0600,deploy,root,-)
/etc/init.d/kadeploy_server
/etc/kadeploy3/nodes
/etc/kadeploy3/specific_conf_g5kdev-cluster
/etc/kadeploy3/fdisk_g5kdev-cluster
/etc/kadeploy3/cmd
/etc/kadeploy3/conf
%defattr(0400,deploy,root,-)
%dir /.keys
/.keys/id_deploy
%defattr(0755,deploy,root,-)
/usr/bin/kastafior
/usr/sbin/kadeploy_server
/usr/sbin/karights

%doc

%changelog
