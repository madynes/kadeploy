Name:           kadeploy-client
Version:        3
Release:        beta%{?dist}
Summary:        Client part of the Kadeploy deployment tool.
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
%dir /usr/bin
%defattr(0755,deploy,root,-)
/etc/kadeploy3/client_conf
%defattr(0755,deploy,root,-)
/usr/bin/kaconsole
/usr/bin/kanodes
/usr/bin/kastat
/usr/bin/kadeploy
/usr/bin/kaenv
/usr/bin/kareboot

%doc

%changelog
