# OpenQA settings for apache2. This file is meant to be shared
# between the http and the https vhosts.
#
DocumentRoot /usr/share/openqa/public

<Directory "/usr/share/openqa/public">
    AllowOverride None
    Require all granted
</Directory>

<Directory "/var/lib/openqa/share/factory">
    AllowOverride None
    Require all granted
    # Need to set explicit type, see
    # https://progress.opensuse.org/issues/68362
    # https://httpd.apache.org/docs/2.4/mod/mod_mime.html#addtype
    AddType application/octet-stream qcow2
</Directory>
Alias /assets "/var/lib/openqa/share/factory"

<Directory "/var/lib/openqa/cache/archives">
    AllowOverride None
    Require all granted
</Directory>
Alias /archives "/var/lib/openqa/cache/archives"

<Directory "/var/lib/openqa/images">
  Options SymLinksIfOwnerMatch
  AllowOverride None
  Require all granted

   # Use of ETag is discouraged when Last-Modified is present
  Header unset ETag
  FileETag None
  # RFC says only cache for 1 year
  ExpiresActive On
  ExpiresDefault "access plus 1 year"
</Directory>
Alias /image "/var/lib/openqa/images"

<Directory "/var/lib/os-autoinst/tests">
    AllowOverride None
    Require all granted
</Directory>

<Proxy *>
    Require all granted
</Proxy>

ProxyRequests Off
ProxyPreserveHost On

ProxyPass /robots.txt !
ProxyPass /favicon.ico !
ProxyPass /images !
ProxyPass /image !
ProxyPass /javascripts !
ProxyPass /stylesheets !
ProxyPass /assets !
ProxyPass /archives !
ProxyPass /error !

# ensure websocket connections are handled as such by the reverse proxy while
# still being able to pass regular HTTP connections through it
RewriteEngine On
RewriteCond %{HTTP:Connection} Upgrade [NC]
RewriteCond %{HTTP:Upgrade} websocket [NC]
RewriteRule /api/v1/ws/(.*) ws://localhost:9527/api/v1/ws/$1 [P,L]
RewriteCond %{HTTP:Connection} Upgrade [NC]
RewriteCond %{HTTP:Upgrade} websocket [NC]
RewriteRule /liveviewhandler/(.*) ws://localhost:9528/liveviewhandler/$1 [P,L]

# pass websocket server where the worker connects to port 9527
ProxyPass "/api/v1/ws/" "http://localhost:9527/api/v1/ws/" keepalive=On

# pass websocket server to handle live view to port 9528
ProxyPass "/liveviewhandler/" "http://localhost:9528/liveviewhandler/" keepalive=On

ProxyPass / http://localhost:9526/ keepalive=On
ProxyPassReverse / http://localhost:9526/

<If "%{HTTPS} == 'on'">
RequestHeader set X-Forwarded-HTTPS "1"
RequestHeader set X-Forwarded-Proto "https"
</If>

HostnameLookups Off
UseCanonicalName Off
ServerSignature On
# TODO: try mojo 7.39 - https://github.com/kraih/mojo/commit/f9ff45e48f606
SetEnv proxy-nokeepalive 1

# Increase the timeout from 60s (default) to 300s to ensure that the large
# requests could finish without proxy timeouts problems.
# This value could be enough but not necessary. More investigation needed
ProxyTimeout 300
