# This Dockfile was generated from openQA Makefile with command
# m4 -P -D M4_TEST=t/05-scheduler-full.t docker/direct_test.m4
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




WORKDIR /opt/os-autoinst
RUN git clone --depth=1 https://github.com/os-autoinst/os-autoinst ../os-autoinst
RUN autoreconf -f -i  && ./configure && make
ENV FULLSTACK 1
ENV DEVELOPER_FULLSTACK 1
ENV SCHEDULER_FULLSTACK 1
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
RUN chown -R $USER:$USER ../os-autoinst
USER $USER

ENV TEST_PG='DBI:Pg:dbname=openqa_test;host=/opt/openqa/tpg'
RUN t/test_postgresql /opt/openqa/tpg
RUN mkdir db
ENV STARTDB='pg_ctl -D /opt/openqa/tpg -l logfile start'

RUN ( $STARTDB; eval $(dbus-launch --sh-syntax); prove -v t/05-scheduler-full.t )

