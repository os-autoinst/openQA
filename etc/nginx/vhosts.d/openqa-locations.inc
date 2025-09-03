## Optional faster assets downloads for large deployments
#location /assets {
#    include vhosts.d/openqa-assets.inc;
#
#    ## Alternatively, make a redirect to a different subdomain in accordance
#    ## with the file_subdomain in openQA config
#    #return 301 http://file.$host$request_uri;
#}

include vhosts.d/openqa-endpoints.inc;
