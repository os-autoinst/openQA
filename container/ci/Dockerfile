#!BuildTag: openqa_dev
FROM opensuse/leap:15.3

# Define environment variable
ENV NAME openQA test environment
ENV LANG en_US.UTF-8

RUN zypper ar -f -G 'http://download.opensuse.org/repositories/devel:/openQA:/Leap:/15.3/openSUSE_Leap_15.3' devel_openqa

# hadolint ignore=DL3037
RUN zypper in -y -C \
       glibc-i18ndata \
       glibc-locale \
       automake \
       curl \
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
       python3-base \
       python3-requests \
       python3-future \
       sqlite3 \
       postgresql-server \
       which \
       chromedriver \
       xorg-x11-fonts \
       'rubygem(sass)' \
       perl \
       ShellCheck \
       python3-setuptools \
       python3-yamllint \
       sudo \
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
       'perl(IO::Scalar)' \
       'perl(IO::Socket::SSL)' \
       'perl(IPC::Run)' \
       'perl(IPC::System::Simple)' \
       'perl(JSON::XS)' \
       'perl(JavaScript::Minifier::XS)' \
       'perl(LWP::Protocol::https)' \
       'perl(Minion) >= 10.0' \
       'perl(Module::CPANfile)' \
       'perl(Module::Pluggable)' \
       'perl(Mojo::IOLoop::ReadWriteProcess)' \
       'perl(Mojo::Pg)' \
       'perl(Mojo::RabbitMQ::Client)' \
       'perl(Mojo::SQLite)' \
       'perl(Minion::Backend::SQLite)' \
       'perl(Mojolicious)' \
       'perl(Mojolicious::Plugin::AssetPack)' \
       'perl(Mojolicious::Plugin::RenderFile)' \
       'perl(JSON::Validator)' \
       'perl(YAML::PP) >= 0.020' \
       'perl(YAML::XS) >= 0.67' \
       'perl(Net::OpenID::Consumer)' \
       'perl(Net::SNMP)' \
       'perl(Net::SSH2)' \
       'perl(Perl::Critic)' \
       'perl(Perl::Critic::Freenode)' \
       'perl(Perl::Tidy)' \
       'perl(Pod::POM)' \
       'perl(Pod::Coverage)' \
       'perl(Pod::Spell)' \
       'perl(SQL::SplitStatement)' \
       'perl(SQL::Translator)' \
       'perl(Selenium::Remote::Driver)' \
       'perl(Socket::MsgHdr)' \
       'perl(Sort::Versions)' \
       'perl(Test::Compile)' \
       'perl(Test::Strict)' \
       'perl(Test::Fatal)' \
       'perl(Test::Pod)' \
       'perl(Test::Mock::Time)' \
       'perl(Test::MockModule)' \
       'perl(Test::MockObject)' \
       'perl(Test::Output)' \
       'perl(Socket::MsgHdr)' \
       'perl(Test::Warnings) >= 0.029' \
       'perl(Text::Diff)' \
       'perl(CommonMark)' \
       'perl(Time::ParseDate)' \
       'perl(XSLoader) >= 0.24' \
       'perl(XML::SemanticDiff)' \
       'perl(File::Map)' \
       perl-Archive-Extract \
       perl-Test-Simple \
       'perl(aliased)' \
       aspell-spell \
       aspell-en \
       systemd-sysvinit \
       systemd libudev1 tack && \
    zypper clean

VOLUME ["/sys/fs/cgroup", "/run"]

CMD ["/sbin/init"]

ENV OPENQA_DIR /opt/openqa
ENV NORMAL_USER squamata

RUN echo "$NORMAL_USER ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers && \
    mkdir -p /home/$NORMAL_USER && \
    useradd -r -d /home/$NORMAL_USER -g users --uid=1000 $NORMAL_USER && \
    chown $NORMAL_USER:users /home/$NORMAL_USER
VOLUME [ "/opt/openqa" ]

# explicitly set user/group IDs
RUN mkdir -p /opt/testing_area && \
    chown -R $NORMAL_USER:users /opt/testing_area

ENTRYPOINT ["/bin/bash"]
WORKDIR $OPENQA_DIR
