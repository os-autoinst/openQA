# OpenQA settings for apache2. This file is meant to be shared
# between the http and the https vhosts.
#
DocumentRoot /usr/share/openqa/public

<Directory "/usr/share/openqa/public">
    AllowOverride None
    Order allow,deny
    Allow from all
</Directory>

<Directory "/var/lib/openqa/share/factory">
    AllowOverride None
    Order allow,deny
    Allow from all
</Directory>
Alias /assets "/var/lib/openqa/share/factory"

<Directory "/var/lib/os-autoinst/tests">
    AllowOverride None
    Order allow,deny
    Allow from all
</Directory>

<Proxy *>
Order deny,allow
Allow from all
</Proxy>

ProxyRequests Off
ProxyPreserveHost On

ProxyPass /favicon.ico !
ProxyPass /images !
ProxyPass /javascripts !
ProxyPass /stylesheets !
ProxyPass /assets !
ProxyPass /error !

ProxyPass / http://localhost:9526/ keepalive=On
ProxyPassReverse / http://localhost:9526/

<If "%{HTTPS} == 'on'">
RequestHeader set X-Forwarded-HTTPS "1"
RequestHeader set X-Forwarded-Proto "https"
</If>
<Else>
RequestHeader set X-Forwarded-HTTPS "0"
RequestHeader set X-Forwarded-Proto "http"
</Else>

HostnameLookups Off
UseCanonicalName Off
ServerSignature On

# vim: syntax=apache
