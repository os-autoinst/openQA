#!/bin/bash

#echo video/ogg ogv >> /etc/mime.types
zypper in make apache2 perl-PerlMagick vorbis-tools perl-Perl-Tidy perl-Text-MicroTemplate-Extended perl-JSON withlock
#cpan Text::MicroTemplate::Extended

cp -a etc/apache2/* /etc/apache2/
cp -a www/* /srv/www/
cp -a tools/autoinstctl /usr/local/bin/

a2enmod rewrite
/etc/init.d/apache2 restart

mkdir -p logs
chown geekotest.www logs perl/autoinst/testimgs schedule.d # make it writable for apache
chmod g+w logs perl/autoinst/testimgs schedule.d
