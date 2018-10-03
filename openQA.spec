#
# spec file for package openQA
#
# Copyright (c) 2018 SUSE LINUX GmbH, Nuernberg, Germany.
#
# All modifications and additions to the file contributed by third parties
# remain the property of their copyright owners, unless otherwise agreed
# upon. The license for this file, and modifications and additions to the
# file, is the same license as for the pristine package itself (unless the
# license for the pristine package is not an Open Source License, in which
# case the license is the MIT License). An "Open Source License" is a
# license that conforms to the Open Source Definition (Version 1.9)
# published by the Open Source Initiative.

# Please submit bugfixes or comments via http://bugs.opensuse.org/
#


# can't use linebreaks here!
%define openqa_services openqa-webui.service openqa-gru.service openqa-websockets.service openqa-scheduler.service openqa-resource-allocator.service
%define openqa_worker_services openqa-worker.target openqa-slirpvde.service openqa-vde_switch.service
%if %{undefined tmpfiles_create}
%define tmpfiles_create() \
%{_bindir}/systemd-tmpfiles --create %{?*} || : \
%{nil}
%endif
%if 0%{?suse_version} >= 1550
%ifarch x86_64
%bcond_without tests
%else
%bcond_with tests
%endif
%else
%bcond_with tests
%endif
# runtime requirements that also the testsuite needs
%define t_requires perl(DBD::Pg) perl(DBIx::Class) perl(Config::IniFiles) perl(SQL::Translator) perl(Date::Format) perl(File::Copy::Recursive) perl(DateTime::Format::Pg) perl(Net::OpenID::Consumer) perl(Mojolicious::Plugin::RenderFile) perl(Mojolicious::Plugin::AssetPack) perl(aliased) perl(Config::Tiny) perl(DBIx::Class::DynamicDefault) perl(DBIx::Class::Schema::Config) perl(DBIx::Class::Storage::Statistics) perl(IO::Socket::SSL) perl(Data::Dump) perl(DBIx::Class::OptimisticLocking) perl(Text::Markdown) perl(Net::DBus) perl(IPC::Run) perl(Archive::Extract) perl(CSS::Minifier::XS) perl(JavaScript::Minifier::XS) perl(Time::ParseDate) perl(Sort::Versions) perl(Mojo::RabbitMQ::Client) perl(BSD::Resource) perl(Cpanel::JSON::XS) perl(Pod::POM) perl(Mojo::IOLoop::ReadWriteProcess) perl(Minion) perl(Mojo::Pg) perl(Mojo::SQLite) perl(Minion::Backend::SQLite)
Name:           openQA
Version:        4.6
Release:        0
Summary:        The openQA web-frontend, scheduler and tools
License:        GPL-2.0-or-later
Group:          Development/Tools/Other
Url:            http://os-autoinst.github.io/openQA/
Source0:        %{name}-%{version}.tar.xz
# a workaround for set_version looking at random files (so we can't name it .tar.xz)
# use update-cache to update it
Source1:        cache.txz
Source100:      openQA-rpmlintrc
Source101:      update-cache.sh
Source102:      Dockerfile
BuildRequires:  %{t_requires}
BuildRequires:  fdupes
BuildRequires:  os-autoinst
BuildRequires:  systemd
# critical bug fix
BuildRequires:  perl(DBIx::Class) >= 0.082801
BuildRequires:  perl(Minion) >= 9.02
BuildRequires:  perl(Mojolicious) >= 7.92
BuildRequires:  perl(Mojolicious::Plugin::AssetPack) >= 1.36
BuildRequires:  rubygem(sass)
Requires:       dbus-1
Requires:       perl(Minion) >= 9.02
Requires:       perl(Mojo::RabbitMQ::Client) >= 0.2
# needed for test suite
Requires:       git-core
Requires:       openQA-client = %{version}
Requires:       openQA-common = %{version}
# needed for saving needles optimized
Requires:       optipng
Requires:       perl(DBIx::Class) >= 0.082801
# needed for openid support
Requires:       perl(LWP::Protocol::https)
Requires:       perl(URI)
# we need to have the same sha1 as expected
%requires_eq    perl-Mojolicious-Plugin-AssetPack
Recommends:     %{name}-local-db
Requires(post): coreutils
Requires(post): perl(DBIx::Class::DeploymentHandler)
Requires(post): perl(SQL::SplitStatement)
Recommends:     apache2
Recommends:     apparmor-profiles
Recommends:     apparmor-utils
Recommends:     logrotate
BuildRequires:  postgresql-server
BuildArch:      noarch
ExcludeArch:    i586
%{?systemd_requires}
%if %{with tests}
BuildRequires:  chromedriver
BuildRequires:  chromium
BuildRequires:  glibc-locale
# pick a font so chromium has something to render - doesn't matter so much
BuildRequires:  dejavu-fonts
BuildRequires:  google-roboto-fonts
BuildRequires:  perl-App-cpanminus
BuildRequires:  perl(DBD::SQLite)
BuildRequires:  perl(Mojo::RabbitMQ::Client) >= 0.2
BuildRequires:  perl(Perl::Critic)
BuildRequires:  perl(Perl::Tidy)
BuildRequires:  perl(Selenium::Remote::Driver) >= 1.20
BuildRequires:  perl(Test::Compile)
BuildRequires:  perl(Test::MockObject)
BuildRequires:  perl(Test::Warnings)
%endif
%if 0%{?suse_version} >= 1330
Requires(pre):  group(nogroup)
%endif

%description
openQA is a testing framework that allows you to test GUI applications on one
hand and bootloader and kernel on the other. In both cases, it is difficult to
script tests and verify the output. Output can be a popup window or it can be
an error in early boot even before init is executed.

openQA is an automated test tool that makes it possible to test the whole
installation process of an operating system. It uses virtual machines to
reproduce the process, check the output (both serial console and screen) in
every step and send the necessary keystrokes and commands to proceed to the
next. openQA can check whether the system can be installed, whether it works
properly in 'live' mode, whether applications work or whether the system
responds as expected to different installation options and commands.

Even more importantly, openQA can run several combinations of tests for every
revision of the operating system, reporting the errors detected for each
combination of hardware configuration, installation options and variant of the
operating system.

%package common
Summary:        The openQA common tools for web-frontend and workers
Group:          Development/Tools/Other
Requires:       %{t_requires}
Requires:       perl(Mojolicious) >= 7.92

%description common
This package contain shared resources for openQA web-frontend and
openQA workers.

%package worker
Summary:        The openQA worker
Group:          Development/Tools/Other
Requires:       openQA-client = %{version}
Requires:       os-autoinst < 5
Requires:       perl(DBD::SQLite)
Requires:       perl(Minion::Backend::SQLite)
Requires:       perl(Mojo::SQLite)
Requires:       perl(Mojo::IOLoop::ReadWriteProcess) > 0.19
Requires:       perl(SQL::SplitStatement)
# FIXME: use proper Requires(pre/post/preun/...)
PreReq:         openQA-common = %{version}
Requires(post): coreutils
Requires(post): os-autoinst >= 4.4
Recommends:     qemu
%if 0%{?suse_version} >= 1330
Requires(pre):  group(nogroup)
%endif

%description worker
The openQA worker manages test engine (provided by os-autoinst package).

%package client
Summary:        Client tools for remote openQA management
Group:          Development/Tools/Other
Requires:       openQA-common = %{version}
Requires:       perl(Config::IniFiles)
Requires:       perl(Cpanel::JSON::XS)
Requires:       perl(Data::Dump)
Requires:       perl(Getopt::Long)
Requires:       perl(IO::Socket::SSL) >= 2.009
Requires:       perl(JSON)
Requires:       perl(LWP::UserAgent)
Requires:       perl(Mojolicious)
Requires:       perl(Try::Tiny)

%description client
Tools and support files for openQA client script. Client script is
a convenient helper for interacting with openQA webui REST API.

%package local-db
Summary:        Helper package to ease setup of postgresql DB
Group:          Development/Tools/Other
Requires:       %name
Requires:       postgresql-server
Supplements:    packageand(%name:postgresql-server)

%description local-db
You only need this package if you have a local postgresql server
next to the webui.

%package doc
Summary:        The openQA documentation
Group:          Development/Tools/Other

%description doc
Documentation material covering installation, configuration, basic test writing, etc.
Covering both openQA and also os-autoinst test engine.

%prep
%setup -q -a1

%build
make %{?_smp_mflags}

%check
#for double checking
%if %{with tests}
cpanm --installdeps --with-feature=test .
%endif

# we don't really need the tidy test
rm -f t/00-tidy.t

%if %{with tests}
#make test
rm -rf %{buildroot}/DB
export LC_ALL=en_US.UTF-8
./t/test_postgresql %{buildroot}/DB
export TEST_PG="DBI:Pg:dbname=openqa_test;host=%{buildroot}/DB"
MOJO_LOG_LEVEL=debug OBS_RUN=1 prove -rv || true
pg_ctl -D %{buildroot}/DB stop
rm -rf %{buildroot}/DB
%endif

%install
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8
%make_install

mkdir -p %{buildroot}%{_datadir}/openqa%{_sysconfdir}/openqa
ln -s %{_sysconfdir}/openqa/openqa.ini %{buildroot}%{_datadir}/openqa%{_sysconfdir}/openqa/openqa.ini
ln -s %{_sysconfdir}/openqa/database.ini %{buildroot}%{_datadir}/openqa%{_sysconfdir}/openqa/database.ini
mkdir -p %{buildroot}%{_bindir}
ln -s %{_datadir}/openqa/script/client %{buildroot}%{_bindir}/openqa-client
ln -s %{_datadir}/openqa/script/clone_job.pl %{buildroot}%{_bindir}/openqa-clone-job
ln -s %{_datadir}/openqa/script/dump_templates %{buildroot}%{_bindir}/openqa-dump-templates
ln -s %{_datadir}/openqa/script/load_templates %{buildroot}%{_bindir}/openqa-load-templates

cd %{buildroot}
grep -rl %{_bindir}/env . | while read file; do
    sed -e 's,%{_bindir}/env perl,%{_bindir}/perl,' -i $file
done
mkdir -p %{buildroot}%{_sbindir}
for i in webui gru worker resource-allocator scheduler websockets slirpvde vde_switch livehandler; do
    ln -s ../sbin/service %{buildroot}%{_sbindir}/rcopenqa-$i
done
#
install -D -m 644 /dev/null %{buildroot}%{_localstatedir}/log/openqa
install -m 0644 %{_sourcedir}/openQA.changes %{buildroot}%{_datadir}/openqa/public/Changelog
#
mkdir %{buildroot}%{_localstatedir}/lib/openqa/pool/1
mkdir %{buildroot}%{_localstatedir}/lib/openqa/cache
mkdir %{buildroot}%{_localstatedir}/lib/openqa/webui
mkdir %{buildroot}%{_localstatedir}/lib/openqa/webui/cache
#
%fdupes %{buildroot}/%{_prefix}

%pre
if ! getent passwd geekotest > /dev/null; then
    %{_sbindir}/useradd -r -g nogroup -c "openQA user" \
        -d %{_localstatedir}/lib/openqa geekotest 2>/dev/null || :
fi

%service_add_pre %{openqa_services}

%pre common
if [ "$1" = 1 ]; then
  # upgrade from openQA -> openQA-common (before -> after package split)
  # old data needs to be moved to new locations else cpio fail during package deploying
  if [ -d "%{_localstatedir}/lib/openqa/" -a ! -d "%{_localstatedir}/lib/openqa/share" ]; then
    echo "### performing migration of openQA data"
    mkdir "%{_localstatedir}/lib/openqa/share"
    if [ -e "%{_localstatedir}/lib/openqa/factory" ]; then
      echo "### moving %{_localstatedir}/lib/openqa/factory to %{_localstatedir}/lib/openqa/share/"
      mv "%{_localstatedir}/lib/openqa/factory" "%{_localstatedir}/lib/openqa/share/"
    fi
  fi
fi

%pre worker
if ! getent passwd _openqa-worker > /dev/null; then
  %{_sbindir}/useradd -r -g nogroup -c "openQA worker" \
    -d %{_localstatedir}/lib/empty _openqa-worker 2>/dev/null || :
  # might fail for non-kvm workers (qemu package owns the group)
  %{_sbindir}/usermod _openqa-worker -a -G kvm || :
fi

%service_add_pre %{openqa_worker_services}

%post
# install empty log file
if [ ! -e %{_localstatedir}/log/openqa ]; then
        install -D -m 644 -o geekotest /dev/null %{_localstatedir}/log/openqa || :
fi

if [ $1 -eq 1 ]; then
    echo "### copy and edit %{_sysconfdir}/apache2/vhosts.d/openqa.conf.template!"
    echo "### run sudo %{_datadir}/openqa/script/fetchneedles"
else
    if [ -d "%{_localstatedir}/lib/openqa/share/testresults" ]; then
        # remove the symlink
        rm "%{_localstatedir}/lib/openqa/testresults"
        mv "%{_localstatedir}/lib/openqa/share/testresults" "%{_localstatedir}/lib/openqa/"
    fi

    # we don't want to require the scheduler for the webui (so we can stop it independent)
    # but it should be enabled together with the webui
    if test "$(systemctl is-enabled openqa-webui.service)" = "enabled"; then
        systemctl enable openqa-scheduler.service
    fi
fi

%service_add_post %{openqa_services}

%post worker
%tmpfiles_create %{_tmpfilesdir}/openqa.conf
%service_add_post %{openqa_worker_services}

%preun
%service_del_preun %{openqa_services}

%preun worker
%service_del_preun %{openqa_worker_services}

%postun
%service_del_postun %{openqa_services}
%restart_on_update boot.apparmor

%postun worker
%service_del_postun %{openqa_worker_services}

%post local-db
%service_add_post openqa-setup-db.service

%preun local-db
%service_del_preun openqa-setup-db.service

%postun local-db
%service_del_postun openqa-setup-db.service

%files
%doc README.asciidoc
%{_sbindir}/rcopenqa-gru
%{_sbindir}/rcopenqa-scheduler
%{_sbindir}/rcopenqa-resource-allocator
%{_sbindir}/rcopenqa-websockets
%{_sbindir}/rcopenqa-webui
%{_sbindir}/rcopenqa-livehandler
%dir %{_sysconfdir}/openqa
%config(noreplace) %attr(-,geekotest,root) %{_sysconfdir}/openqa/openqa.ini
%config(noreplace) %attr(-,geekotest,root) %{_sysconfdir}/openqa/database.ini
%dir %{_datadir}/openqa
%dir %{_datadir}/openqa/etc
%dir %{_datadir}/openqa%{_sysconfdir}/openqa
%{_datadir}/openqa%{_sysconfdir}/openqa/openqa.ini
%{_datadir}/openqa%{_sysconfdir}/openqa/database.ini
%config %{_sysconfdir}/logrotate.d
%config(noreplace) %{_sysconfdir}/dbus-1/system.d/org.opensuse.openqa.conf
# apache vhost
%dir %{_sysconfdir}/apache2
%dir %{_sysconfdir}/apache2/vhosts.d
%config %{_sysconfdir}/apache2/vhosts.d/openqa.conf.template
%config %{_sysconfdir}/apache2/vhosts.d/openqa-common.inc
%config %{_sysconfdir}/apache2/vhosts.d/openqa-ssl.conf.template
# apparmor profile
%dir %{_sysconfdir}/apparmor.d
%config %{_sysconfdir}/apparmor.d/usr.share.openqa.script.openqa
# init
%dir %{_unitdir}
%{_unitdir}/openqa-webui.service
%{_unitdir}/openqa-livehandler.service
%{_unitdir}/openqa-gru.service
%{_unitdir}/openqa-scheduler.service
%{_unitdir}/openqa-resource-allocator.service
%{_unitdir}/openqa-websockets.service
# web libs
%dir %{_datadir}/openqa
%{_datadir}/openqa/templates
%{_datadir}/openqa/public
%{_datadir}/openqa/assets
%{_datadir}/openqa/dbicdh
%{_datadir}/openqa/script/check_dependencies
%{_datadir}/openqa/script/clean_needles
%{_datadir}/openqa/script/create_admin
%{_datadir}/openqa/script/fetchneedles
%{_datadir}/openqa/script/initdb
%{_datadir}/openqa/script/openqa
%{_datadir}/openqa/script/openqa-scheduler
%{_datadir}/openqa/script/openqa-resource-allocator
%{_datadir}/openqa/script/openqa-websockets
%{_datadir}/openqa/script/openqa-livehandler
%{_datadir}/openqa/script/upgradedb
%{_datadir}/openqa/script/modify_needle
# TODO: define final user
%defattr(-,geekotest,root)
# attention: never package subdirectories owned by a user other
# than root as that opens a security hole!
%dir %{_localstatedir}/lib/openqa/db
%dir %{_localstatedir}/lib/openqa/images
%dir %{_localstatedir}/lib/openqa/webui
%dir %{_localstatedir}/lib/openqa/webui/cache
%{_localstatedir}/lib/openqa/testresults
%dir %{_localstatedir}/lib/openqa/share/tests
%dir %{_localstatedir}/lib/openqa/share/factory
# iso hdd repo must be geekotest writable to enable *_URL and HDD upload functionality
%dir %{_localstatedir}/lib/openqa/share/factory/iso
%dir %{_localstatedir}/lib/openqa/share/factory/hdd
%dir %{_localstatedir}/lib/openqa/share/factory/repo
%dir %{_localstatedir}/lib/openqa/share/factory/other
%ghost %{_localstatedir}/lib/openqa/db/db.sqlite
%ghost %{_localstatedir}/log/openqa

%files common
%dir %{_datadir}/openqa
%{_datadir}/openqa/lib
%exclude %{_datadir}/openqa/lib/OpenQA/Client.pm
%exclude %{_datadir}/openqa/lib/OpenQA/Client
%exclude %{_datadir}/openqa/lib/OpenQA/UserAgent.pm
%dir %{_localstatedir}/lib/openqa
%ghost %dir %{_localstatedir}/lib/openqa/share/
%{_localstatedir}/lib/openqa/factory
%{_localstatedir}/lib/openqa/script
%{_localstatedir}/lib/openqa/tests

%files worker
%{_sbindir}/rcopenqa-slirpvde
%{_sbindir}/rcopenqa-vde_switch
%{_sbindir}/rcopenqa-worker
%config(noreplace) %{_sysconfdir}/openqa/workers.ini
%config(noreplace) %attr(0400,_openqa-worker,root) %{_sysconfdir}/openqa/client.conf
# apparmor profile
%dir %{_sysconfdir}/apparmor.d
%config %{_sysconfdir}/apparmor.d/usr.share.openqa.script.worker
# init
%dir %{_unitdir}
%{_libexecdir}/systemd/system-generators
%{_unitdir}/openqa-worker.target
%{_unitdir}/openqa-worker@.service
%{_unitdir}/openqa-worker-no-cleanup@.service
%{_unitdir}/openqa-slirpvde.service
%{_unitdir}/openqa-vde_switch.service
%{_tmpfilesdir}/openqa.conf
%ghost %dir %{_rundir}/openqa
# worker libs
%dir %{_datadir}/openqa
%dir %{_datadir}/openqa/script
%{_datadir}/openqa/script/worker
%dir %{_localstatedir}/lib/openqa/pool
%defattr(-,_openqa-worker,root)
%dir %{_localstatedir}/lib/openqa/cache
# own one pool - to create the others is task of the admin
%dir %{_localstatedir}/lib/openqa/pool/1

%files client
%dir %{_datadir}/openqa
%dir %{_datadir}/openqa/script
%{_datadir}/openqa/script/client
%{_datadir}/openqa/script/clone_job.pl
%{_datadir}/openqa/script/dump_templates
%{_datadir}/openqa/script/load_templates
%dir %{_datadir}/openqa/lib
%{_datadir}/openqa/lib/OpenQA/Client.pm
%{_datadir}/openqa/lib/OpenQA/Client
%{_datadir}/openqa/lib/OpenQA/UserAgent.pm
%{_bindir}/openqa-client
%{_bindir}/openqa-clone-job
%{_bindir}/openqa-dump-templates
%{_bindir}/openqa-load-templates

%files doc
%doc docs/*

%files local-db
%{_unitdir}/openqa-setup-db.service

%changelog
