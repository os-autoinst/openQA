#
# spec file for package openQA
#
# Copyright 2018-2020 SUSE LLC
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
%define openqa_main_service openqa-webui.service
%define openqa_extra_services openqa-gru.service openqa-websockets.service openqa-scheduler.service openqa-enqueue-audit-event-cleanup.service openqa-enqueue-audit-event-cleanup.timer openqa-enqueue-asset-cleanup.service openqa-enqueue-git-auto-update.service openqa-enqueue-asset-cleanup.timer openqa-enqueue-result-cleanup.service openqa-enqueue-result-cleanup.timer openqa-enqueue-bug-cleanup.service openqa-enqueue-bug-cleanup.timer openqa-enqueue-git-auto-update.timer openqa-enqueue-needle-ref-cleanup.service openqa-enqueue-needle-ref-cleanup.timer
%define openqa_services %{openqa_main_service} %{openqa_extra_services}
%define openqa_worker_services openqa-worker.target openqa-slirpvde.service openqa-vde_switch.service openqa-worker-cacheservice.service openqa-worker-cacheservice-minion.service
%define openqa_localdb_services openqa-setup-db.service openqa-dump-db.service openqa-dump-db.timer
%if %{undefined tmpfiles_create}
%define tmpfiles_create() \
%{_bindir}/systemd-tmpfiles --create %{?*} || : \
%{nil}
%endif
# Run tests on openSUSE Tumbleweed and supported openSUSE Leap versions
%if 0%{?is_opensuse} && 0%{?suse_version} >= 1500
%ifarch x86_64
%bcond_without tests
%else
%bcond_with tests
%endif
%else
%bcond_with tests
%endif
# SLE < 15 does not provide many of the dependencies for the python sub-package
%if 0%{?suse_version} < 1500 && !0%{?is_opensuse}
%bcond_with python_scripts
%else
%bcond_without python_scripts
%endif
# exclude additional sub packages that would pull in a lot of extra dependencies on SLE
%if 0%{?suse_version} && !0%{?is_opensuse}
%bcond_with devel_package
%bcond_with munin_package
%else
%bcond_without devel_package
%bcond_without munin_package
%endif
# runtime requirements that also the testsuite needs
%if %{with python_scripts}
%define python_scripts_requires python3-base python3-requests openQA-client
%else
%define python_scripts_requires %{nil}
%endif
# The following line is generated from dependencies.yaml
%define assetpack_requires perl(CSS::Minifier::XS) >= 0.01 perl(JavaScript::Minifier::XS) >= 0.11 perl(Mojolicious) perl(Mojolicious::Plugin::AssetPack) >= 1.36 perl(YAML::PP) >= 0.026
# The following line is generated from dependencies.yaml
%define common_requires ntp-daemon perl >= 5.20.0 perl(Carp::Always) >= 0.14.02 perl(Config::IniFiles) perl(Config::Tiny) perl(Cpanel::JSON::XS) >= 4.09 perl(Cwd) perl(Data::Dump) perl(Data::Dumper) perl(Digest::MD5) perl(Feature::Compat::Try) perl(Filesys::Df) perl(Getopt::Long) perl(Minion) >= 10.25 perl(Mojolicious) >= 9.340.0 perl(Regexp::Common) perl(Storable) perl(Text::Glob) perl(Time::Moment)
# runtime requirements for the main package that are not required by other sub-packages
# The following line is generated from dependencies.yaml
%define main_requires %assetpack_requires bsdtar git-core hostname openssh-clients perl(BSD::Resource) perl(Carp) perl(CommonMark) perl(Config::Tiny) perl(DBD::Pg) >= 3.7.4 perl(DBI) >= 1.632 perl(DBIx::Class) >= 0.082801 perl(DBIx::Class::DeploymentHandler) perl(DBIx::Class::DynamicDefault) perl(DBIx::Class::OptimisticLocking) perl(DBIx::Class::ResultClass::HashRefInflator) perl(DBIx::Class::Schema::Config) perl(DBIx::Class::Storage::Statistics) perl(Date::Format) perl(DateTime) perl(DateTime::Duration) perl(DateTime::Format::Pg) perl(Exporter) perl(Fcntl) perl(File::Basename) perl(File::Copy) perl(File::Copy::Recursive) perl(File::Path) perl(File::Spec) perl(FindBin) perl(Getopt::Long::Descriptive) perl(IO::Handle) perl(IPC::Run) perl(JSON::Validator) perl(LWP::UserAgent) perl(Module::Load::Conditional) perl(Module::Pluggable) perl(Mojo::Base) perl(Mojo::ByteStream) perl(Mojo::IOLoop) perl(Mojo::JSON) perl(Mojo::Pg) perl(Mojo::RabbitMQ::Client) >= 0.2 perl(Mojo::URL) perl(Mojo::Util) perl(Mojolicious::Commands) perl(Mojolicious::Plugin) perl(Mojolicious::Plugin::OAuth2) perl(Mojolicious::Static) perl(Net::OpenID::Consumer) perl(POSIX) perl(Pod::POM) perl(SQL::Translator) perl(Scalar::Util) perl(Sort::Versions) perl(Text::Diff) perl(Time::HiRes) perl(Time::ParseDate) perl(Time::Piece) perl(Time::Seconds) perl(URI::Escape) perl(YAML::PP) >= 0.026 perl(YAML::XS) perl(aliased) perl(base) perl(constant) perl(diagnostics) perl(strict) perl(warnings)
# The following line is generated from dependencies.yaml
%define client_requires curl git-core jq perl(Getopt::Long::Descriptive) perl(IO::Socket::SSL) >= 2.009 perl(IPC::Run) perl(JSON::Validator) perl(LWP::Protocol::https) perl(LWP::UserAgent) perl(Test::More) perl(YAML::PP) >= 0.020 perl(YAML::XS)
# The following line is generated from dependencies.yaml
%define worker_requires bsdtar openQA-client optipng os-autoinst perl(Capture::Tiny) perl(File::Map) perl(Minion::Backend::SQLite) >= 5.0.7 perl(Mojo::IOLoop::ReadWriteProcess) >= 0.26 perl(Mojo::SQLite) psmisc sqlite3 >= 3.24.0
# The following line is generated from dependencies.yaml
%define mcp_requires perl(MCP)
%if 0%{?suse_version} < 1570
# SLE <= 15 has older Perl not providing a sufficiently recent
# ExtUtils::ParseXS needed by ExtUtils::CppGuess
# See https://progress.opensuse.org/issues/162500 for details
%define build_requires %assetpack_requires npm rubygem(sass) >= 3.7.4
%else
# The following line is generated from dependencies.yaml
%define build_requires %assetpack_requires npm perl(CSS::Sass) python3-argparse-manpage
%endif

# All requirements needed by the tests executed during build-time.
# Do not require on this in individual sub-packages except for the devel
# package.
# The following line is generated from dependencies.yaml
%define test_requires %common_requires %main_requires %mcp_requires %python_scripts_requires %worker_requires curl jq openssh-common os-autoinst perl(App::cpanminus) perl(Selenium::Remote::Driver) >= 1.23 perl(Selenium::Remote::WDKeys) perl(Test::Exception) perl(Test::Fatal) perl(Test::MockModule) perl(Test::MockObject) perl(Test::Mojo) perl(Test::Most) perl(Test::Output) perl(Test::Pod) perl(Test::Strict) perl(Test::Warnings) >= 0.029 postgresql-server python3-setuptools
%ifarch x86_64
%define qemu qemu qemu-kvm
%else
%define qemu qemu
%endif
# The following line is generated from dependencies.yaml
%define style_check_requires ShellCheck perl(Code::TidyAll) perl(Perl::Critic) perl(Perl::Critic::Community) python3-yamllint shfmt
# The following line is generated from dependencies.yaml
%define cover_requires perl(Devel::Cover) perl(Devel::Cover::Report::Codecovbash)
# The following line is generated from dependencies.yaml
%define devel_no_selenium_requires %build_requires %cover_requires %qemu %style_check_requires %test_requires curl perl(Perl::Tidy) perl(Test::CheckGitStatus) postgresql-devel rsync sudo tar xorg-x11-fonts
# The following line is generated from dependencies.yaml
%define devel_requires %devel_no_selenium_requires chromedriver

Name:           openQA
Version:        5
Release:        0
Summary:        The openQA web-frontend, scheduler and tools
License:        GPL-2.0-or-later
Url:            http://os-autoinst.github.io/openQA/
Source0:        %{name}-%{version}.tar.xz
Source1:        openQA-rpmlintrc
Source2:        node_modules.spec.inc
%include        %{_sourcedir}/node_modules.spec.inc
BuildRequires:  fdupes
# for install-opensuse in Makefile
BuildRequires:  distribution-release
BuildRequires:  %{build_requires}
BuildRequires:  apparmor-rpm-macros
BuildRequires:  local-npm-registry
Requires:       perl(Minion) >= 10.0
Requires:       %{main_requires}
Requires:       openQA-client = %{version}
Requires:       openQA-common = %{version}
# we need to have the same sha1 as expected
%requires_eq    perl-Mojolicious-Plugin-AssetPack
Recommends:     %{name}-local-db
Requires(post): coreutils
Requires(post): perl(SQL::SplitStatement)
Recommends:     apache2
Recommends:     apparmor-profiles
Recommends:     apparmor-utils
Recommends:     logrotate
# the plugin is needed if the auth method is set to "oauth2"
Recommends:     perl(Mojolicious::Plugin::OAuth2)
# required to decompress .tar.xz compressed disk images/isos
Recommends:     perl(IO::Uncompress::UnXz)
# server needs to run an rsync server if worker caching is used
Recommends:     rsync
# We cannot use noarch because of the strict perl-Mojolicious-Plugin-AssetPack
# requirement. With noarch it can happen that the rpm built on aarch64 gets
# uploaded to download.opensuse.org, and aarch for some reason has an older
# version of that module. Then when we install on Tumbleweed, it doesn't
# have that older version anymore
#BuildArch:      noarch
ExcludeArch:    %{ix86}
%{?systemd_requires}
%if %{with tests}
BuildRequires:  %{test_requires}
%endif
Requires(pre):  group(nogroup)
%if 0%{?suse_version} > 1500
BuildRequires:  sysuser-tools
%sysusers_requires
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

%if %{with devel_package}
%package no-selenium-devel
Summary:        Development package pulling in all build+test dependencies except chromedriver for Selenium based tests
Requires:       %{devel_no_selenium_requires}

%description no-selenium-devel
Development package pulling in all build+test dependencies except chromedriver for Selenium based tests.

%package devel
Summary:        Development package pulling in all build+test dependencies
Requires:       %{devel_requires}

%description devel
Development package pulling in all build+test dependencies.
%endif

%package common
Summary:        The openQA common tools for web-frontend and workers
Requires:       %{common_requires}
Requires:       perl(Mojolicious) >= 8.24

%description common
This package contain shared resources for openQA web-frontend and
openQA workers.

%package worker
Summary:        The openQA worker
%define worker_requires_including_uncovered_in_tests %worker_requires perl(SQL::SplitStatement)
Requires:       %{worker_requires_including_uncovered_in_tests}
# FIXME: use proper Requires(pre/post/preun/...)
PreReq:         openQA-common = %{version}
Requires(post): coreutils
Requires(post): os-autoinst >= 4.6
Recommends:     qemu
# Needed for caching - not required if caching not used...
Recommends:     rsync
# Optionally enabled with USE_PNGQUANT=1
Recommends:     pngquant
# for Build Service Authentication
Recommends:     openssh-common
%if 0%{?suse_version} >= 1330
Requires(pre):  group(nogroup)
Requires(pre):  group(kvm)
%endif

%description worker
The openQA worker manages test engine (provided by os-autoinst package).

%package mcp
Summary:        Additional MCP package for AI support in openQA
Requires:       %{mcp_requires}

%description mcp
This package contains a plugin for AI support in openQA.

%package client
Summary:        Client tools for remote openQA management
Requires:       openQA-common = %{version}
Requires:       %client_requires

%description client
Tools and support files for openQA client script. Client script is
a convenient helper for interacting with openQA webui REST API.

%if %{with python_scripts}
%package python-scripts
Summary:        Additional scripts in python
Requires:       %python_scripts_requires

%description python-scripts
Additional scripts for the use of openQA in the python programming language.
%endif

%package local-db
Summary:        Helper package to ease setup of postgresql DB
Requires:       %{name} = %{version}
Requires:       postgresql-server
BuildRequires:  postgresql-server
Supplements:    packageand(%name:postgresql-server)

%description local-db
You only need this package if you have a local postgresql server
next to the webui.

%package single-instance
Summary:        Convenience package for a single-instance setup using apache proxy
Provides:       %{name}-single-instance-apache
Provides:       %{name}-single-instance-apache2
Requires:       %{name}-local-db
Requires:       %{name} = %{version}
Requires:       %{name}-worker = %{version}
Requires:       apache2

%description single-instance
Use this package to setup a local instance with all services provided together.

%package single-instance-nginx
Summary:        Convenience package for a single-instance setup using nginx proxy
Requires:       %{name}-local-db
Requires:       %{name} = %{version}
Requires:       %{name}-worker = %{version}
Requires:       nginx

%description single-instance-nginx
Use this package to setup a local instance with all services provided together.

%package bootstrap
Summary:        Automated openQA setup
Requires:       curl
Requires:       iputils
Requires:       procps

%description bootstrap
This can automatically setup openQA - either directly on your system
or within a systemd-nspawn container.

%package doc
Summary:        The openQA documentation

%description doc
Documentation material covering installation, configuration, basic test writing, etc.
Covering both openQA and also os-autoinst test engine.

%package auto-update
Summary:        Automatically upgrade and reboot the system when required
Requires:       %{name}-common
Requires:       curl
Requires:       rebootmgr

%description auto-update
Use this package to install and enable a systemd service for nightly upgrading
and rebooting the system if devel:openQA packages are stable.

%package continuous-update
Summary:        Continuously update packages from devel:openQA
Requires:       %{name}-common
Requires:       curl

%description continuous-update
Use this package to install and enable a systemd service for continuously
upgrading the system if devel:openQA packages are stable and contain updates. It
is complementary to auto-update which also reboots the system and does updates
regardless of whether devel:openQA contains updates.

%if %{with munin_package}
%package munin
Summary:        Munin scripts
Requires:       munin
Requires:       munin-node
Requires:       curl
Requires:       perl

%description munin
Use this package to install munin scripts that allow to monitor some openQA
statistics.
%endif


%prep
%setup -q
sed -e 's,/bin/env python,/bin/python,' -i script/openqa-label-all
local-npm-registry %{_sourcedir} install --omit=dev --legacy-peer-deps --no-package-lock

%build
%make_build
%if 0%{?suse_version} > 1500
%sysusers_generate_pre usr/lib/sysusers.d/%{name}-worker.conf %{name}-worker %{name}-worker.conf
%sysusers_generate_pre usr/lib/sysusers.d/geekotest.conf %{name} geekotest.conf
%endif

%check
#for double checking
%if %{with tests}
sed -i '/Perl::Tidy/d' cpanfile
cpanm -n --mirror http://no.where/ --installdeps --with-feature=test .
%endif

# we don't really need the tidy test
rm -f t/00-tidy.t

%if %{with tests}
rm -rf %{buildroot}/DB
export LC_ALL=en_US.UTF-8
# Skip tests not working currently, or flaky, and Selenium tests
# https://progress.opensuse.org/issues/19652
# 01-test-utilities.t: https://progress.opensuse.org/issues/73162
# 17-labels_carry_over.t: https://progress.opensuse.org/issues/60209
# api/14-plugin_obs_rsync_async.t: https://progress.opensuse.org/issues/68836
# t/43-scheduling-and-worker-scalability.t: https://progress.opensuse.org/issues/96545
rm \
    t/01-test-utilities.t \
    t/17-labels_carry_over.t \
    t/25-cache-service.t \
    t/api/14-plugin_obs_rsync_async.t \
    t/43-scheduling-and-worker-scalability.t \
    t/ui/*.t

# "CI" set with longer timeouts as needed for higher performance variations
# within CI systems, e.g. OBS. See t/lib/OpenQA/Test/TimeLimit.pm
export CI=1
export OPENQA_TEST_TIMEOUT_SCALE_CI=10
# Skip container tests that would need additional requirements, e.g.
# docker-compose. Also, these tests are less relevant (or not relevant) for
# packaging
export CONTAINER_TEST=0
export HELM_TEST=0
# We don't want fatal warnings during package building
export PERL_TEST_WARNINGS_ONLY_REPORT_WARNINGS=1
make test PROVE_ARGS='-r -v t' CHECKSTYLE=0 TEST_PG_PATH=%{buildroot}/DB
rm -rf %{buildroot}/DB
%endif

%install
%if !%{with python_scripts}
rm script/openqa-label-all
%endif
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8
%make_install

%if 0%{?suse_version} <= 1500
# we only use sysusers on Tumbleweed
rm -rf %{buildroot}/%{_sysusersdir}
%endif

%if 0%{?suse_version} > 1560
# the limit set via sysctl is already present on Tumbleweed and packaging sysctl config would require a security review
rm -rf %{buildroot}/%{_prefix}/lib/sysctl.d/01-openqa-reload-worker-auto-restart.conf
%endif

mkdir -p %{buildroot}%{_bindir}
ln -s %{_datadir}/openqa/script/client %{buildroot}%{_bindir}/openqa-client
ln -s %{_datadir}/openqa/script/openqa-cli %{buildroot}%{_bindir}/openqa-cli
ln -s %{_datadir}/openqa/script/openqa-clone-job %{buildroot}%{_bindir}/openqa-clone-job
ln -s %{_datadir}/openqa/script/openqa-dump-templates %{buildroot}%{_bindir}/openqa-dump-templates
ln -s %{_datadir}/openqa/script/openqa-load-templates %{buildroot}%{_bindir}/openqa-load-templates
ln -s %{_datadir}/openqa/script/openqa-clone-custom-git-refspec %{buildroot}%{_bindir}/openqa-clone-custom-git-refspec
ln -s %{_datadir}/openqa/script/openqa-validate-yaml %{buildroot}%{_bindir}/openqa-validate-yaml
ln -s %{_datadir}/openqa/script/setup-db %{buildroot}%{_bindir}/openqa-setup-db
ln -s %{_datadir}/openqa/script/dump-db %{buildroot}%{_bindir}/openqa-dump-db
%if %{with python_scripts}
ln -s %{_datadir}/openqa/script/openqa-label-all %{buildroot}%{_bindir}/openqa-label-all
%endif

install -d -m 755 %{buildroot}%{_datadir}/openqa/client
install -m 755 public/openqa-cli.yaml %{buildroot}%{_datadir}/openqa/client/openqa-cli.yaml

# munin
%if %{with munin_package}
install -d -m 755 %{buildroot}/%{_prefix}/lib/munin/plugins
install -m 755 contrib/munin/plugins/minion %{buildroot}/%{_prefix}/lib/munin/plugins/openqa_minion_
install -d -m 755 %{buildroot}/%{_sysconfdir}/munin/plugin-conf.d
install -m 644 contrib/munin/config/minion.config %{buildroot}/%{_sysconfdir}/munin/plugin-conf.d/openqa-minion
install -m 755 contrib/munin/utils/munin-mail %{buildroot}/%{_datadir}/openqa/script/munin-mail
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
%fdupes %{buildroot}/%{_prefix}

%if 0%{?suse_version} > 1500
%pre -f %{name}.pre
%else
%pre
if ! getent passwd geekotest > /dev/null; then
    %{_sbindir}/useradd -r -g nogroup -c "openQA user" \
        -d %{_localstatedir}/lib/openqa geekotest 2>/dev/null || :
fi
%endif

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

%if 0%{?suse_version} > 1500
%pre worker -f openQA-worker.pre
%else
%pre worker
if ! getent passwd _openqa-worker > /dev/null; then
  %{_sbindir}/useradd -r -g nogroup -c "openQA worker" \
    -d %{_localstatedir}/lib/empty _openqa-worker 2>/dev/null || :
  # might fail for non-kvm workers (qemu package owns the group)
  %{_sbindir}/usermod _openqa-worker -a -G kvm || :
fi
%endif

%service_add_pre %{openqa_worker_services}

%pre auto-update
%service_add_pre openqa-auto-update.timer

%pre continuous-update
%service_add_pre openqa-continuous-update.timer

%post
%tmpfiles_create %{_tmpfilesdir}/openqa-webui.conf
# install empty log file
if [ ! -e %{_localstatedir}/log/openqa ]; then
        install -D -m 644 -o geekotest /dev/null %{_localstatedir}/log/openqa || :
fi

if [ $1 -eq 1 ]; then
    echo "### copy and edit %{_sysconfdir}/apache2/vhosts.d/openqa.conf.template if using apache!"
    echo "### copy and edit %{_sysconfdir}/nginx/vhosts.d/openqa.conf.template if using nginx!"
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

%post auto-update
%service_add_post openqa-auto-update.timer

%post continuous-update
%service_add_post openqa-continuous-update.timer

%preun
%service_del_preun %{openqa_services}

%preun worker
%service_del_preun %{openqa_worker_services}

%preun auto-update
# not changing the service which might have triggered this update itself
%service_del_preun openqa-auto-update.timer

%preun continuous-update
# not changing the service which might have triggered this update itself
%service_del_preun openqa-continuous-update.timer

%postun
# reload main service (but do not restart it via service_del_postun to minimize downtimes)
if [ -x /usr/bin/systemctl ] && [ $1 -ge 1 ]; then
    /usr/bin/systemctl reload %{openqa_main_service} || :
fi
# restart other services
%service_del_postun %{openqa_extra_services}
# reload AppArmor profiles
%apparmor_reload %{_sysconfdir}/apparmor.d/usr.share.openqa.script.openqa
%apparmor_reload %{_sysconfdir}/apparmor.d/local/usr.share.openqa.script.openqa

%postun worker
# reload AppArmor profiles
%apparmor_reload %{_sysconfdir}/apparmor.d/usr.share.openqa.script.worker
%apparmor_reload %{_sysconfdir}/apparmor.d/local/usr.share.openqa.script.worker
# restart worker services on updates; does *not* include services for worker slots unless openqa-worker.target
# is running at the time of the update
%service_del_postun %{openqa_worker_services}
# restart running openqa-worker-auto-restart@.service units without interrupting jobs
# notes: noop if no such units are running; daemon-reload already done by service_del_postun macro;
#        "$1 -ge 1" checks for a package upgrade
if [ -x /usr/bin/systemctl ] && [ $1 -ge 1 ]; then
    /usr/bin/systemctl reload 'openqa-worker-auto-restart@*.service' || :
fi

%postun auto-update
%service_del_postun openqa-auto-update.timer

%postun continuous-update
%service_del_postun openqa-continuous-update.timer

%post local-db
%service_add_post %{openqa_localdb_services}

%preun local-db
%service_del_preun %{openqa_localdb_services}

%postun local-db
%service_del_postun %{openqa_localdb_services}

%files
%doc README.asciidoc
%{_sbindir}/rcopenqa-gru
%{_sbindir}/rcopenqa-scheduler
%{_sbindir}/rcopenqa-websockets
%{_sbindir}/rcopenqa-webui
%{_sbindir}/rcopenqa-livehandler
%ghost %config(noreplace) %attr(0644,geekotest,root) %{_sysconfdir}/openqa/openqa.ini
%ghost %config(noreplace) %attr(0640,geekotest,root) %{_sysconfdir}/openqa/database.ini
%dir %{_sysconfdir}/openqa
%dir %{_sysconfdir}/openqa/openqa.ini.d
%dir %{_sysconfdir}/openqa/database.ini.d
%{_datadir}/doc/openqa/examples/openqa.ini
%{_datadir}/doc/openqa/examples/database.ini
%dir %{_datadir}/openqa
%config %{_sysconfdir}/logrotate.d
# apache vhost
%dir %{_sysconfdir}/apache2
%dir %{_sysconfdir}/apache2/vhosts.d
%config %{_sysconfdir}/apache2/vhosts.d/openqa.conf.template
%config(noreplace) %{_sysconfdir}/apache2/vhosts.d/openqa-common.inc
%config %{_sysconfdir}/apache2/vhosts.d/openqa-ssl.conf.template
# nginx vhost
%dir %{_sysconfdir}/nginx
%dir %{_sysconfdir}/nginx/vhosts.d
%config %{_sysconfdir}/nginx/vhosts.d/openqa.conf.template
%config(noreplace) %{_sysconfdir}/nginx/vhosts.d/openqa-assets.inc
%config(noreplace) %{_sysconfdir}/nginx/vhosts.d/openqa-endpoints.inc
%config(noreplace) %{_sysconfdir}/nginx/vhosts.d/openqa-locations.inc
%config(noreplace) %{_sysconfdir}/nginx/vhosts.d/openqa-upstreams.inc
# apparmor profile
%dir %{_sysconfdir}/apparmor.d
%config %{_sysconfdir}/apparmor.d/usr.share.openqa.script.openqa
%dir %{_sysconfdir}/apparmor.d/local
%config %{_sysconfdir}/apparmor.d/local/usr.share.openqa.script.openqa
# init
%dir %{_unitdir}
%{_unitdir}/openqa-webui.service
%{_unitdir}/openqa-livehandler.service
%{_unitdir}/openqa-gru.service
%dir %{_unitdir}/openqa-gru.service.requires
%{_unitdir}/openqa-scheduler.service
%dir %{_unitdir}/openqa-scheduler.service.requires
%{_unitdir}/openqa-websockets.service
%dir %{_unitdir}/openqa-websockets.service.requires
%{_unitdir}/openqa-enqueue-audit-event-cleanup.service
%{_unitdir}/openqa-enqueue-audit-event-cleanup.timer
%{_unitdir}/openqa-enqueue-asset-cleanup.service
%{_unitdir}/openqa-enqueue-asset-cleanup.timer
%{_unitdir}/openqa-enqueue-git-auto-update.service
%{_unitdir}/openqa-enqueue-git-auto-update.timer
%{_unitdir}/openqa-enqueue-result-cleanup.service
%{_unitdir}/openqa-enqueue-result-cleanup.timer
%{_unitdir}/openqa-enqueue-bug-cleanup.service
%{_unitdir}/openqa-enqueue-bug-cleanup.timer
%{_unitdir}/openqa-enqueue-needle-ref-cleanup.service
%{_unitdir}/openqa-enqueue-needle-ref-cleanup.timer
%{_tmpfilesdir}/openqa-webui.conf
# web libs
%dir %{_datadir}/openqa
%{_datadir}/openqa/lib/DBIx/
%{_datadir}/openqa/lib/OpenQA/LiveHandler.pm
%{_datadir}/openqa/lib/OpenQA/Resource/
%{_datadir}/openqa/lib/OpenQA/Scheduler/
%{_datadir}/openqa/lib/OpenQA/Schema/
%{_datadir}/openqa/lib/OpenQA/WebAPI/
%exclude %{_datadir}/openqa/lib/OpenQA/WebAPI/Plugin/MCP.pm
%{_datadir}/openqa/lib/OpenQA/WebSockets/
%{_datadir}/openqa/templates
%{_datadir}/openqa/public
%{_datadir}/openqa/assets
%{_datadir}/openqa/dbicdh
%{_datadir}/openqa/node_modules
%{_datadir}/openqa/script/configure-web-proxy
%{_datadir}/openqa/script/create_admin
%{_datadir}/openqa/script/fetchneedles
%{_datadir}/openqa/script/initdb
%{_datadir}/openqa/script/openqa
%{_datadir}/openqa/script/openqa-scheduler
%{_datadir}/openqa/script/openqa-scheduler-daemon
%{_datadir}/openqa/script/openqa-websockets
%{_datadir}/openqa/script/openqa-websockets-daemon
%{_datadir}/openqa/script/openqa-livehandler
%{_datadir}/openqa/script/openqa-livehandler-daemon
%{_datadir}/openqa/script/openqa-enqueue-asset-cleanup
%{_datadir}/openqa/script/openqa-enqueue-audit-event-cleanup
%{_datadir}/openqa/script/openqa-enqueue-bug-cleanup
%{_datadir}/openqa/script/openqa-enqueue-git-auto-update
%{_datadir}/openqa/script/openqa-enqueue-result-cleanup
%{_datadir}/openqa/script/openqa-gru
%{_datadir}/openqa/script/openqa-rollback
%{_datadir}/openqa/script/openqa-webui-daemon
%{_datadir}/openqa/script/upgradedb
%{_datadir}/openqa/script/modify_needle
%{_datadir}/openqa/script/openqa-enqueue-needle-ref-cleanup
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
%ghost %{_localstatedir}/log/openqa
%if 0%{?suse_version} > 1500
%{_sysusersdir}/geekotest.conf
%endif

%if %{with devel_package}
%files devel
%endif

%files common
%if 0%{?suse_version} < 1550
%endif
%dir %{_datadir}/doc/openqa
%dir %{_datadir}/doc/openqa/examples
%dir %{_datadir}/openqa
%{_datadir}/openqa/lib
%exclude %{_datadir}/openqa/lib/OpenQA/CacheService/
%exclude %{_datadir}/openqa/lib/DBIx/
%exclude %{_datadir}/openqa/lib/OpenQA/Client.pm
%exclude %{_datadir}/openqa/lib/OpenQA/Client
%exclude %{_datadir}/openqa/lib/OpenQA/UserAgent.pm
%exclude %{_datadir}/openqa/lib/OpenQA/LiveHandler.pm
%exclude %{_datadir}/openqa/lib/OpenQA/Resource/
%exclude %{_datadir}/openqa/lib/OpenQA/Scheduler/
%exclude %{_datadir}/openqa/lib/OpenQA/Schema/
%exclude %{_datadir}/openqa/lib/OpenQA/WebAPI/
%exclude %{_datadir}/openqa/lib/OpenQA/WebSockets/
%exclude %{_datadir}/openqa/lib/OpenQA/Worker/
%dir %{_localstatedir}/lib/openqa
%ghost %dir %{_localstatedir}/lib/openqa/share/
%{_localstatedir}/lib/openqa/factory
%{_localstatedir}/lib/openqa/script
%{_localstatedir}/lib/openqa/tests
%{_datadir}/openqa/script/openqa-check-devel-repo
%{_datadir}/openqa/script/openqa-clean-repo-cache
%{_unitdir}/openqa-minion-restart.service
%{_unitdir}/openqa-minion-restart.path

%files worker
%{_datadir}/openqa/lib/OpenQA/CacheService/
%{_datadir}/openqa/lib/OpenQA/Worker/
%{_sbindir}/rcopenqa-slirpvde
%{_sbindir}/rcopenqa-vde_switch
%{_sbindir}/rcopenqa-worker
%ghost %config(noreplace) %attr(0644,root,root) %{_sysconfdir}/openqa/workers.ini
%ghost %config(noreplace) %attr(0400,_openqa-worker,root) %{_sysconfdir}/openqa/client.conf
%dir %{_sysconfdir}/openqa/workers.ini.d
%dir %{_sysconfdir}/openqa/client.conf.d
%{_datadir}/doc/openqa/examples/workers.ini
%{_datadir}/doc/openqa/examples/client.conf
# apparmor profile
%dir %{_sysconfdir}/apparmor.d
%config %{_sysconfdir}/apparmor.d/usr.share.openqa.script.worker
%dir %{_sysconfdir}/apparmor.d/local
%config %{_sysconfdir}/apparmor.d/local/usr.share.openqa.script.worker
# init
%dir %{_unitdir}
%{_systemdgeneratordir}
%{_unitdir}/openqa-worker.target
%{_unitdir}/openqa-worker.slice
%{_unitdir}/openqa-worker@.service
%{_unitdir}/openqa-worker-plain@.service
%{_unitdir}/openqa-worker-cacheservice-minion.service
%{_unitdir}/openqa-worker-cacheservice.service
%{_unitdir}/openqa-worker-no-cleanup@.service
%{_unitdir}/openqa-worker-auto-restart@.service
%{_unitdir}/openqa-reload-worker-auto-restart@.service
%{_unitdir}/openqa-reload-worker-auto-restart@.path
%{_unitdir}/openqa-slirpvde.service
%{_unitdir}/openqa-vde_switch.service
%{_datadir}/openqa/script/openqa-slirpvde
%{_datadir}/openqa/script/openqa-vde_switch
%{_tmpfilesdir}/openqa.conf
%ghost %dir %attr(0755,_openqa-worker,root) %{_rundir}/openqa
# worker libs
%dir %{_datadir}/openqa
%dir %{_datadir}/openqa/script
%{_datadir}/openqa/script/worker
%{_datadir}/openqa/script/openqa-workercache
%{_datadir}/openqa/script/openqa-workercache-daemon
%{_datadir}/openqa/script/openqa-worker-cacheservice-minion
%dir %{_localstatedir}/lib/openqa/pool
%defattr(-,_openqa-worker,root)
%dir %{_localstatedir}/lib/openqa/cache
# own one pool - to create the others is task of the admin
%dir %{_localstatedir}/lib/openqa/pool/1
%if 0%{?suse_version} > 1500
%{_sysusersdir}/%{name}-worker.conf
%endif
%if 0%{?suse_version} <= 1560
%{_prefix}/lib/sysctl.d/01-openqa-reload-worker-auto-restart.conf
%endif

%files client
%dir %{_datadir}/openqa
%dir %{_datadir}/openqa/client
%{_datadir}/openqa/client/openqa-cli.yaml
%dir %{_datadir}/openqa/script
%{_datadir}/openqa/script/client
%{_datadir}/openqa/script/clone_job.pl
%{_datadir}/openqa/script/dump_templates
%{_datadir}/openqa/script/load_templates
%{_datadir}/openqa/script/openqa-dump-templates
%{_datadir}/openqa/script/openqa-load-templates
%{_datadir}/openqa/script/openqa-cli
%{_datadir}/openqa/script/openqa-clone-job
%{_datadir}/openqa/script/openqa-clone-custom-git-refspec
%{_datadir}/openqa/script/openqa-validate-yaml
%dir %{_datadir}/openqa/lib
%{_datadir}/openqa/lib/OpenQA/Client.pm
%{_datadir}/openqa/lib/OpenQA/Client
%{_datadir}/openqa/lib/OpenQA/UserAgent.pm
%{_bindir}/openqa-client
%{_bindir}/openqa-cli
%{_bindir}/openqa-clone-job
%{_bindir}/openqa-dump-templates
%{_bindir}/openqa-load-templates
%{_bindir}/openqa-clone-custom-git-refspec
%{_bindir}/openqa-validate-yaml

%if %{with python_scripts}
%files python-scripts
%{_datadir}/openqa/script/openqa-label-all
%{_bindir}/openqa-label-all
%endif

%files doc
%doc docs/*

%files local-db
%{_unitdir}/openqa-setup-db.service
%{_unitdir}/openqa-dump-db.service
%{_unitdir}/openqa-dump-db.timer
%{_unitdir}/openqa-gru.service.requires/postgresql.service
%{_unitdir}/openqa-scheduler.service.requires/postgresql.service
%{_unitdir}/openqa-websockets.service.requires/postgresql.service
%{_datadir}/openqa/script/setup-db
%{_datadir}/openqa/script/dump-db
%{_bindir}/openqa-setup-db
%{_bindir}/openqa-dump-db
%dir %attr(0755,postgres,root) %{_localstatedir}/lib/openqa/backup

%files single-instance

%files single-instance-nginx

%files bootstrap
%{_datadir}/openqa/script/openqa-bootstrap
%{_datadir}/openqa/script/openqa-bootstrap-container

%files auto-update
%dir %{_unitdir}
%{_unitdir}/openqa-auto-update.*
%{_datadir}/openqa/script/openqa-auto-update

%files continuous-update
%dir %{_unitdir}
%{_unitdir}/openqa-continuous-update.*
%{_datadir}/openqa/script/openqa-continuous-update

%if %{with munin_package}
%files munin
%defattr(-,root,root)
%doc contrib/munin/config/minion.config
%dir %{_datadir}/openqa/script
%dir %{_prefix}/lib/munin
%dir %{_prefix}/lib/munin/plugins
%dir %{_sysconfdir}/munin
%dir %{_sysconfdir}/munin/plugin-conf.d
%{_prefix}/lib/munin/plugins/openqa_minion_
%{_datadir}/openqa/script/munin-mail
%config(noreplace) %{_sysconfdir}/munin/plugin-conf.d/openqa-minion
%endif

%files mcp
%{_datadir}/openqa/lib/OpenQA/WebAPI/Plugin/MCP.pm

%changelog
