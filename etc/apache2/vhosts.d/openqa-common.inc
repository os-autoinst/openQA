# OpenQA settings for apache2. This file is meant to be shared
# between the http and the https vhosts.
#
DocumentRoot /usr/share/openqa/public

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
</If>
<Else>
RequestHeader set X-Forwarded-HTTPS "0"
</Else>

HostnameLookups Off
UseCanonicalName Off
ServerSignature On

# vim: syntax=apache
