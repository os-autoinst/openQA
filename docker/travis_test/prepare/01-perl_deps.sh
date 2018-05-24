#!/bin/bash

echo "#######################################################"
echo "#      Starting perl and perl deps installation      #"
echo "#######################################################"

zypper in -y -C 'perl(Archive::Extract)' \
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
       'perl(Digest::MD5)>= 2.55' \
       'perl(Data::OptList)' \
       'perl(DateTime::Format::Pg)' \
       'perl(DateTime::Format::SQLite)' \
       'perl(Devel::Cover)' \
       'perl(ExtUtils::MakeMaker)>=7.12' \
       'perl(Exception::Class)' \
       'perl(File::Copy::Recursive)' \
       'perl(IO::Socket::SSL)' \
       'perl(IPC::Run)' \
       'perl(IPC::System::Simple)' \
       'perl(JSON::XS)' \
       'perl(JavaScript::Minifier::XS)' \
       'perl(LWP::Protocol::https)' \
       'perl(Minion)' \
       'perl(Mojo::IOLoop::ReadWriteProcess)' \
       'perl(Mojo::Pg)' \
       'perl(Mojo::RabbitMQ::Client)' \
       'perl(Mojolicious)' \
       'perl(Mojolicious::Plugin::AssetPack)' \
       'perl(Mojolicious::Plugin::RenderFile)' \
       'perl(Net::DBus)' \
       'perl(Net::OpenID::Consumer)' \
       'perl(Net::SNMP)' \
       'perl(Net::SSH2)' \
       'perl(Perl::Critic)' \
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
       'perl(XSLoader)>=0.24' \
       'TimeDate' \
       perl-Archive-Extract \
       perl-Test-Simple \
        perl-Net-DBus \
       'perl(aliased)'

