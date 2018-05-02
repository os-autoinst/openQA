#!/bin/bash

echo "#######################################################"
echo "#      Starting perl and perl deps installation      #"
echo "#######################################################"

zypper ar -G -f "https://download.opensuse.org/repositories/devel:/languages:/perl/openSUSE_Leap_42.3/devel:languages:perl.repo"

zypper in -y perl-Archive-Extract \
       perl-BSD-Resource \
       perl-CSS-Minifier-XS \
       perl-Carp-Always \
       perl-Config-IniFiles \
       perl-Config-Tiny \
       perl-Cpanel-JSON-XS \
       perl-Crypt-DES \
       perl-DBD-Pg \
       perl-DBD-SQLite \
       perl-DBIx-Class \
       perl-DBIx-Class-DeploymentHandler \
       perl-DBIx-Class-DynamicDefault \
       perl-DBIx-Class-OptimisticLocking \
       perl-DBIx-Class-Schema-Config \
       perl-Data-Dump \
       perl-Data-OptList \
       perl-DateTime-Format-Pg \
       perl-Devel-Cover \
       perl-ExtUtils-MakeMaker \
       perl-File-Copy-Recursive \
       perl-IO-Socket-SSL \
       perl-IPC-Run \
       perl-IPC-System-Simple \
       perl-JSON-XS \
       perl-JavaScript-Minifier-XS \
       perl-Minion \
       perl-Mojo-IOLoop-ReadWriteProcess \
       perl-Mojo-Pg \
       perl-Mojo-RabbitMQ-Client \
       perl-Mojolicious \
       perl-Mojolicious-Plugin-AssetPack \
       perl-Mojolicious-Plugin-RenderFile \
       perl-Net-DBus \
       perl-Net-OpenID-Consumer \
       perl-Net-SNMP \
       perl-Net-SSH2 \
       perl-Perl-Critic \
       perl-Perl-Tidy \
       perl-Pod-POM \
       perl-SQL-SplitStatement \
       perl-SQL-Translator \
       perl-Selenium-Remote-Driver \
       perl-Socket-MsgHdr \
       perl-Sort-Versions \
       perl-Test-Compile \
       perl-Test-Mock-Time \
       perl-Test-MockModule \
       perl-Test-MockObject \
       perl-Test-Output \
       perl-Test-Warnings \
       perl-Text-Markdown \
       perl-Time-ParseDate \
       perl-TimeDate \
       perl-aliased

