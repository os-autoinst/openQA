#
# spec file for package openQA
#
# Copyright (c) 2019 SUSE LINUX GmbH, Nuernberg, Germany.
#
# All modifications and additions to the file contributed by third parties
# remain the property of their copyright owners, unless otherwise agreed
# upon. The license for this file, and modifications and additions to the
# file, is the same license as for the pristine package itself (unless the
# license for the pristine package is not an Open Source License, in which
# case the license is the MIT License). An "Open Source License" is a
# license that conforms to the Open Source Definition (Version 1.9)
# published by the Open Source Initiative.

# Please submit bugfixes or comments via https://bugs.opensuse.org/
#


# can't use linebreaks here!
%define openqa_services openqa-webui.service openqa-gru.service openqa-websockets.service openqa-scheduler.service openqa-enqueue-audit-event-cleanup.service openqa-enqueue-audit-event-cleanup.timer
%define openqa_worker_services openqa-worker.target openqa-slirpvde.service openqa-vde_switch.service openqa-worker-cacheservice.service openqa-worker-cacheservice-minion.service
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
# SLE < 15 does not provide many of the dependencies for the python sub-package
%if 0%{?sle_version} < 150000 && !0%{?is_opensuse}
%bcond_with python_scripts
%else
%bcond_without python_scripts
%endif
# runtime requirements that also the testsuite needs
%if %{with python_scripts}
%define python_scripts_requires python3-base python3-requests python3-future
%else
%define python_scripts_requires %{nil}
%endif
%define assetpack_requires perl(Mojolicious::Plugin::AssetPack) => 1.36, perl(CSS::Minifier::XS) perl(JavaScript::Minifier::XS)
%define common_requires perl(Config::IniFiles) perl(Cpanel::JSON::XS) perl(Cwd) perl(Data::Dump) perl(Data::Dumper) perl(Digest::MD5) perl(Getopt::Long) perl(Minion) => 9.09, perl(Mojolicious) >= 7.92, perl(Try::Tiny) perl(Regexp::Common)
# runtime requirements for the main package that are not required by other sub-packages
%define main_requires %assetpack_requires git-core perl(Carp::Always) perl(Date::Format) perl(DateTime::Format::Pg) perl(DBD::Pg) >= 3.7.4, perl(DBI) >= 1.632, perl(DBIx::Class) => 0.082801, perl(DBIx::Class::DeploymentHandler) perl(DBIx::Class::DynamicDefault) perl(DBIx::Class::Schema::Config) perl(DBIx::Class::Storage::Statistics) perl(DBIx::Class::OptimisticLocking) perl(File::Copy::Recursive) perl(Net::OpenID::Consumer) perl(Module::Pluggable) perl(aliased) perl(Config::Tiny) perl(Text::Diff) perl(CommonMark) perl(JSON::Validator) perl(IPC::Run) perl(Archive::Extract) perl(Time::ParseDate) perl(Sort::Versions) perl(BSD::Resource) perl(Pod::POM) perl(Mojo::Pg) perl(Mojo::RabbitMQ::Client) => 0.2, perl(SQL::Translator) perl(YAML::XS) perl(LWP::UserAgent)
%define client_requires git-core perl(IO::Socket::SSL) >= 2.009, perl(LWP::UserAgent)
%define worker_requires os-autoinst < 5, perl(Mojo::IOLoop::ReadWriteProcess) > 0.19, perl(Minion::Backend::SQLite) perl(Mojo::SQLite) openQA-client optipng
%define build_requires rubygem(sass) %assetpack_requires

# All requirements needed by the tests executed during build-time.
# Do not require on this in individual sub-packages except for the devel
# package.
%define test_requires %common_requires %main_requires %python_scripts_requires %worker_requires perl(App::cpanminus) perl(Perl::Critic) perl(Perl::Critic::Freenode) perl(Test::Mojo) perl(Test::More) perl(Test::Strict) perl(Test::Fatal) perl(Test::MockModule) perl(Test::Output) perl(Test::Pod) perl(Test::Warnings) perl(Selenium::Remote::Driver) perl(Selenium::Remote::WDKeys) ShellCheck os-autoinst-devel

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
BuildRequires:  %{build_requires}
BuildRequires:  fdupes
Requires:       %{main_requires}
Requires:       openQA-client = %{version}
Requires:       openQA-common = %{version}
Requires:       perl(Minion) >= 9.13
# we need to have the same sha1 as expected
%requires_eq    perl-Mojolicious-Plugin-AssetPack
Recommends:     %{name}-local-db
Requires(post): coreutils
Requires(post): perl(SQL::SplitStatement)
Recommends:     apache2
Recommends:     apparmor-profiles
Recommends:     apparmor-utils
Recommends:     logrotate
# server needs to run an rsync server if worker caching is used
Recommends:     rsync
BuildArch:      noarch
ExcludeArch:    i586
%{?systemd_requires}
%if %{with tests}
BuildRequires:  %{test_requires}
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

%package devel
Summary:        Development package pulling in all build+test dependencies
Group:          Development/Tools/Other
Requires:       %build_requires
Requires:       %main_requires
Requires:       %test_requires
Requires:       curl
Requires:       postgresql-devel
Requires:       postgresql-server
Requires:       qemu
Requires:       qemu-kvm
Requires:       rsync
Requires:       sudo
Requires:       tar
Requires:       xorg-x11-fonts
Requires:       perl(Devel::Cover)
Requires:       perl(Devel::Cover::Report::Codecov)
Requires:       perl(Perl::Tidy)
Requires:       perl(SQL::SplitStatement)

%description devel
Development package pulling in all build+test dependencies.

%package common
Summary:        The openQA common tools for web-frontend and workers
Group:          Development/Tools/Other
Requires:       %{common_requires}
Requires:       perl(Mojolicious) >= 7.92

%description common
This package contain shared resources for openQA web-frontend and
openQA workers.

%package worker
Summary:        The openQA worker
Group:          Development/Tools/Other
%define worker_requires_including_uncovered_in_tests %worker_requires perl(SQL::SplitStatement)
Requires:       %{worker_requires_including_uncovered_in_tests}
# FIXME: use proper Requires(pre/post/preun/...)
PreReq:         openQA-common = %{version}
Requires(post): coreutils
Requires(post): os-autoinst >= 4.4
Recommends:     qemu
# Needed for caching - not required if caching not used...
Recommends:     rsync
%if 0%{?suse_version} >= 1330
Requires(pre):  group(nogroup)
%endif

%description worker
The openQA worker manages test engine (provided by os-autoinst package).

%package client
Summary:        Client tools for remote openQA management
Group:          Development/Tools/Other
Requires:       %client_requires
Requires:       openQA-common = %{version}
Recommends:     jq

%description client
Tools and support files for openQA client script. Client script is
a convenient helper for interacting with openQA webui REST API.

%if %{with python_scripts}
%package python-scripts
Summary:        Additional scripts in python
Group:          Development/Tools/Other
Requires:       %python_scripts_requires

%description python-scripts
Additional scripts for the use of openQA in the python programming language.
%endif

%package local-db
Summary:        Helper package to ease setup of postgresql DB
Group:          Development/Tools/Other
Requires:       %name
Requires:       postgresql-server
Supplements:    packageand(%name:postgresql-server)

%description local-db
You only need this package if you have a local postgresql server
next to the webui.

%package bootstrap
Summary:        Automated openQA setup
Group:          Development/Tools/Other

%description bootstrap
This can automatically setup openQA - either directly on your system
or within a systemd-nspawn container.

%package doc
Summary:        The openQA documentation
Group:          Development/Tools/Other

%description doc
Documentation material covering installation, configuration, basic test writing, etc.
Covering both openQA and also os-autoinst test engine.

%prep
%setup -q -a1
sed -e 's,/bin/env python,/bin/python,' -i script/openqa-label-all

%build
make %{?_smp_mflags}

%check
#for double checking
%if %{with tests}
sed -i '/Perl::Tidy/d' cpanfile
cpanm --installdeps --with-feature=test .
%endif

# we don't really need the tidy test
rm -f t/00-tidy.t

%if %{with tests}
#make test
rm -rf %{buildroot}/DB
export LC_ALL=en_US.UTF-8
make test-with-database OBS_RUN=1 PROVE_ARGS='-l -r -v' TEST_PG_PATH=%{buildroot}/DB || true
rm -rf %{buildroot}/DB
%endif

%install
%if !%{with python_scripts}
rm script/openqa-label-all
%endif
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8
%make_install

mkdir -p %{buildroot}%{_datadir}/openqa%{_sysconfdir}/openqa
ln -s %{_sysconfdir}/openqa/openqa.ini %{buildroot}%{_datadir}/openqa%{_sysconfdir}/openqa/openqa.ini
ln -s %{_sysconfdir}/openqa/database.ini %{buildroot}%{_datadir}/openqa%{_sysconfdir}/openqa/database.ini
mkdir -p %{buildroot}%{_bindir}
ln -s %{_datadir}/openqa/script/client %{buildroot}%{_bindir}/openqa-client
ln -s %{_datadir}/openqa/script/openqa-clone-job %{buildroot}%{_bindir}/openqa-clone-job
ln -s %{_datadir}/openqa/script/dump_templates %{buildroot}%{_bindir}/openqa-dump-templates
ln -s %{_datadir}/openqa/script/load_templates %{buildroot}%{_bindir}/openqa-load-templates
ln -s %{_datadir}/openqa/script/openqa-clone-custom-git-refspec %{buildroot}%{_bindir}/openqa-clone-custom-git-refspec
%if %{with python_scripts}
ln -s %{_datadir}/openqa/script/openqa-label-all %{buildroot}%{_bindir}/openqa-label-all
%endif

cd %{buildroot}
grep -rl %{_bindir}/env . | while read file; do
    sed -e 's,%{_bindir}/env perl,%{_bindir}/perl,' -i $file
done
mkdir -p %{buildroot}%{_sbindir}
for i in webui gru worker scheduler websockets slirpvde vde_switch livehandler; do
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
%restart_on_update apparmor

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
%{_unitdir}/openqa-websockets.service
%{_unitdir}/openqa-enqueue-audit-event-cleanup.service
%{_unitdir}/openqa-enqueue-audit-event-cleanup.timer
# web libs
%dir %{_datadir}/openqa
%{_datadir}/openqa/templates
%{_datadir}/openqa/public
%{_datadir}/openqa/assets
%{_datadir}/openqa/dbicdh
%{_datadir}/openqa/script/check_dependencies
%{_datadir}/openqa/script/create_admin
%{_datadir}/openqa/script/fetchneedles
%{_datadir}/openqa/script/initdb
%{_datadir}/openqa/script/openqa
%{_datadir}/openqa/script/openqa-scheduler
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

%files devel

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
%{_unitdir}/openqa-worker-cacheservice-minion.service
%{_unitdir}/openqa-worker-cacheservice.service
%{_unitdir}/openqa-worker-no-cleanup@.service
%{_unitdir}/openqa-slirpvde.service
%{_unitdir}/openqa-vde_switch.service
%{_tmpfilesdir}/openqa.conf
%ghost %dir %{_rundir}/openqa
# worker libs
%dir %{_datadir}/openqa
%dir %{_datadir}/openqa/script
%{_datadir}/openqa/script/worker
%{_datadir}/openqa/script/openqa-workercache
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
%{_datadir}/openqa/script/openqa-clone-job
%{_datadir}/openqa/script/openqa-clone-custom-git-refspec
%{_datadir}/openqa/script/configure-web-proxy
%dir %{_datadir}/openqa/lib
%{_datadir}/openqa/lib/OpenQA/Client.pm
%{_datadir}/openqa/lib/OpenQA/Client
%{_datadir}/openqa/lib/OpenQA/UserAgent.pm
%{_bindir}/openqa-client
%{_bindir}/openqa-clone-job
%{_bindir}/openqa-dump-templates
%{_bindir}/openqa-load-templates
%{_bindir}/openqa-clone-custom-git-refspec

%if %{with python_scripts}
%files python-scripts
%{_datadir}/openqa/script/openqa-label-all
%{_bindir}/openqa-label-all
%endif

%files doc
%doc docs/*

%files local-db
%{_unitdir}/openqa-setup-db.service

%files bootstrap
%{_datadir}/openqa/script/openqa-bootstrap
%{_datadir}/openqa/script/openqa-bootstrap-container

%changelog
