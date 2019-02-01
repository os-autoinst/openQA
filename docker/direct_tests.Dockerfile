# This Dockfile was generated from openQA Makefile with command
# m4 -P -D M4_TEST=t/*.t docker/direct_test.m4
# And must be called from openQA project folder like
# docker -f docker/<thisfile> .
FROM opensuse:42.3

ENV LANG en_US.UTF-8

RUN zypper ar -f -G "http://download.opensuse.org/repositories/devel:/openQA:/Leap:/42.3/openSUSE_Leap_42.3" devel_openqa

RUN zypper in -y -C glibc-i18ndata

RUN zypper in -y -C glibc-i18ndata \
 glibc-locale \
 automake \
 curl \
 dbus-1-devel \
 fftw3-devel \
 gcc \
 gcc-c++ \
 git \
 gmp-devel \
 gzip \
 libexpat-devel \
 libsndfile-devel \
 libssh2-1 \
 libssh2-devel \
 libtheora-devel \
 libtool \
 libxml2-devel \
 make \
 opencv-devel \
 patch \
 postgresql-devel \
 qemu \
 qemu-tools \
 qemu-kvm \
 tar \
 optipng \
 sqlite3 \
 postgresql-server \
 which \
 chromedriver \
 xorg-x11-fonts \
 'rubygem(sass)' \
 sudo \
 'TimeDate' \
 libudev1 tack

RUN zypper in -y -C perl \
 'perl(App::cpanminus)' \
 'perl(Archive::Extract)' \
 'perl(BSD::Resource)' \
 'perl(CSS::Minifier::XS)' \
 'perl(Carp::Always)' \
 'perl(Class::Accessor::Fast)' \
 'perl(Config)' \
 'perl(Config::IniFiles)' \
 'perl(Config::Tiny)' \
 'perl(Cpanel::JSON::XS)' \
 'perl(Crypt::DES)' \
 'perl(Cwd)' \
 'perl(DBD::Pg)' \
 'perl(DBD::SQLite)' \
 'perl(DBIx::Class)' \
 'perl(DBIx::Class::DeploymentHandler)' \
 'perl(DBIx::Class::DynamicDefault)' \
 'perl(DBIx::Class::OptimisticLocking)' \
 'perl(DBIx::Class::Schema::Config)' \
 'perl(Data::Dump)' \
 'perl(Data::Dumper)' \
 'perl(Digest::MD5) >= 2.55' \
 'perl(Data::OptList)' \
 'perl(DateTime::Format::Pg)' \
 'perl(DateTime::Format::SQLite)' \
 'perl(Devel::Cover)' \
 'perl(Devel::Cover::Report::Codecov)' \
 'perl(ExtUtils::MakeMaker) >= 7.12' \
 'perl(Exception::Class)' \
 'perl(File::Copy::Recursive)' \
 'perl(File::Touch)' \
 'perl(IO::Socket::SSL)' \
 'perl(IPC::Run)' \
 'perl(IPC::System::Simple)' \
 'perl(JSON::XS)' \
 'perl(JavaScript::Minifier::XS)' \
 'perl(LWP::Protocol::https)' \
 'perl(Minion)' \
 'perl(Module::CPANfile)' \
 'perl(Mojo::IOLoop::ReadWriteProcess)' \
 'perl(Mojo::Pg)' \
 'perl(Mojo::RabbitMQ::Client)' \
 'perl(Mojo::SQLite)' \
 'perl(Minion::Backend::SQLite)' \
 'perl(Mojolicious)' \
 'perl(Mojolicious::Plugin::AssetPack)' \
 'perl(Mojolicious::Plugin::RenderFile)' \
 'perl(Net::DBus)' \
 'perl(Net::OpenID::Consumer)' \
 'perl(Net::SNMP)' \
 'perl(Net::SSH2)' \
 'perl(Perl::Critic)' \
 'perl(Perl::Critic::Freenode)' \
 'perl(Perl::Tidy)' \
 'perl(Pod::POM)' \
 'perl(Pod::Coverage)' \
 'perl(SQL::SplitStatement)' \
 'perl(SQL::Translator)' \
 'perl(Selenium::Remote::Driver)' \
 'perl(Socket::MsgHdr)' \
 'perl(Sort::Versions)' \
 'perl(Test::Compile)' \
 'perl(Test::Fatal)' \
 'perl(Test::Pod)' \
 'perl(Test::Mock::Time)' \
 'perl(Test::MockModule)' \
 'perl(Test::MockObject)' \
 'perl(Test::Output)' \
 'perl(Socket::MsgHdr)' \
 'perl(Test::Warnings)' \
 'perl(Text::Markdown)' \
 'perl(Time::ParseDate)' \
 'perl(XSLoader) >= 0.24' \
 'perl(XML::SemanticDiff)' \
 'perl(aliased)' \
 perl-Archive-Extract \
 perl-Test-Simple

RUN zypper in -y -C time vim



WORKDIR /opt/openqa

COPY assets ./assets
COPY cpanfile ./
COPY .perltidyrc ./
COPY dbicdh ./dbicdh
COPY lib ./lib
COPY script ./script
COPY t/ ./t
COPY templates/ ./templates
# must retry because it uses external resourses which sporadically return 404
RUN ( ./script/generate-packed-assets ./ || ./script/generate-packed-assets ./ || ./script/generate-packed-assets ./ )
# postgres is not smart to start with root, so will use their user for testing
ENV USER postgres
ENV NORMAL_USER $USER
ENV OPENQA_USE_DEFAULTS 1
RUN chown -R $USER:$USER .

USER $USER

ENV TEST_PG='DBI:Pg:dbname=openqa_test;host=/opt/openqa/tpg'
RUN t/test_postgresql /opt/openqa/tpg
RUN mkdir db
ENV STARTDB='pg_ctl -D /opt/openqa/tpg -l logfile start'

RUN prove -v t/00-tidy.t
RUN prove -v t/01-compile-check-all.t
RUN prove -v t/02-pod.t
RUN prove -v t/16-utils.t
RUN prove -v t/24-worker-engine.t
RUN prove -v t/25-cache-service.t
RUN prove -v t/25-cache.t
RUN prove -v t/25-serverstartup.t
RUN prove -v t/26-controllerrunning.t
RUN prove -v t/28-logging.t
RUN prove -v t/29-openqa_commands.t
RUN prove -v t/30-test_parser.t
RUN prove -v t/31-api_descriptions.t
RUN prove -v t/31-client_file.t
RUN prove -v t/35-script_clone_job.t
RUN prove -v t/rand.t



RUN ( $STARTDB; prove -v t/04-scheduler.t )
RUN ( $STARTDB; prove -v t/05-scheduler-cancel.t )
RUN ( $STARTDB; prove -v t/05-scheduler-capabilities.t )
RUN ( $STARTDB; prove -v t/05-scheduler-dependencies.t )
RUN ( $STARTDB; prove -v t/05-scheduler-full.t )
RUN ( $STARTDB; prove -v t/05-scheduler-restart-and-duplicate.t )
RUN ( $STARTDB; prove -v t/06-users.t )
RUN ( $STARTDB; prove -v t/07-api_jobtokens.t )
RUN ( $STARTDB; prove -v t/07-api_keys.t )
RUN ( $STARTDB; prove -v t/09-job_clone.t )
RUN ( $STARTDB; prove -v t/10-jobs.t )
RUN ( $STARTDB; prove -v t/10-tests_overview.t )
RUN ( $STARTDB; prove -v t/11-commands.t )
RUN ( $STARTDB; prove -v t/12-profiler.t )
RUN ( $STARTDB; prove -v t/13-joblocks.t )
RUN ( $STARTDB; eval $(dbus-launch --sh-syntax); prove -v t/14-grutasks.t )
RUN ( $STARTDB; prove -v t/15-assets.t )
RUN ( $STARTDB; prove -v t/16-utils-runcmd.t )
RUN ( $STARTDB; prove -v t/17-build_tagging.t )
RUN ( $STARTDB; prove -v t/17-labels_carry_over.t )
RUN ( $STARTDB; prove -v t/18-fedmsg.t )
RUN ( $STARTDB; prove -v t/19-tests-export.t )
RUN ( $STARTDB; prove -v t/20-workers-ws.t )
RUN ( $STARTDB; prove -v t/21-needles.t )
RUN ( $STARTDB; prove -v t/22-dashboard.t )
RUN ( $STARTDB; prove -v t/23-amqp.t )
RUN ( $STARTDB; prove -v t/24-worker.t )
RUN ( $STARTDB; prove -v t/25-bugs.t )
RUN ( $STARTDB; prove -v t/27-errorpages.t )
RUN ( $STARTDB; prove -v t/27-websockets.t )
RUN ( $STARTDB; prove -v t/31-client.t )
RUN ( $STARTDB; prove -v t/32-openqa_client.t )
RUN ( $STARTDB; prove -v t/33-developer_mode.t )
RUN ( $STARTDB; prove -v t/34-developer_mode-unit.t )
RUN ( $STARTDB; prove -v t/36-job_group_defaults.t )
RUN ( $STARTDB; prove -v t/37-limit_assets.t )
RUN ( $STARTDB; prove -v t/basic.t )
RUN ( $STARTDB; prove -v t/config.t )
RUN ( $STARTDB; prove -v t/deploy.t )
RUN ( $STARTDB; prove -v t/full-stack.t )

