#!/bin/bash

#echo video/ogg ogv >> /etc/mime.types
zypper in make apache2 perl-PerlMagick

cp -a etc/apache2/* /etc/apache2/
cp -a www/* /srv/www/

a2enmod rewrite
/etc/init.d/apache2 restart

