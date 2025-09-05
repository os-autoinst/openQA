alias /var/lib/openqa/share/factory/;
## Optional to require authentication for asset downloads
#auth_request /api/v1/auth;
autoindex          on;
tcp_nopush         on;
sendfile           on;
sendfile_max_chunk 1m;

# Enforce download of assets so HTML assets cannot highjack session
# note: Can be disabled when using the alternative of making a redirect to a
#       different domain mentioned in "openqa-locations.inc".
add_header Content-Disposition 'attachment; filename="$1"';
