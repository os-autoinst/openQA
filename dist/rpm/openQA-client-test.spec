%define         short_name openQA-client
Name:           %{short_name}-test
Version:        5
Release:        0
Summary:        Test package for %{short_name}
License:        GPL-2.0-or-later
BuildRequires:  %{short_name} == %{version}
ExcludeArch:    %{ix86}

%description
.

%prep
# workaround to prevent post/install failing assuming this file for whatever
# reason
touch %{_sourcedir}/%{short_name}

%build
openqa-client --help
openqa-cli --help

%install
# disable debug packages in package test to prevent error about missing files
%define debug_package %{nil}

%changelog
