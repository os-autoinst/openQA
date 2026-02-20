alias /var/lib/openqa/cache/archives/;
autoindex          on;
tcp_nopush         on;
sendfile           on;
sendfile_max_chunk 1m;

# Enforce download of archives
add_header Content-Disposition 'attachment; filename="$1"';
