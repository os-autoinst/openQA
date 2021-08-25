%define         short_name openQA
Name:           %{short_name}-test
Version:        4.6
Release:        0
Summary:        Test package for openQA
License:        GPL-2.0-or-later
BuildRequires:  %{short_name} == %{version}
BuildRequires:  openQA-local-db
%if 0%{?suse_version} > 1500
BuildRequires:  user(geekotest)
%endif
ExcludeArch:    i586

%description
.

%prep
# workaround to prevent post/install failing assuming this file for whatever
# reason
touch %{_sourcedir}/%{short_name}

%build
# call one of the components but not openqa itself which would need a valid
# configuration
/usr/share/openqa/script/initdb --help
getent passwd geekotest

%install
# disable debug packages in package test to prevent error about missing files
%define debug_package %{nil}

%changelog
