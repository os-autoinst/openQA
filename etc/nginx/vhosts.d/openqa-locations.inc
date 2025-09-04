## Optional faster assets downloads for large deployments
#location /assets {
#    include vhosts.d/openqa-assets.inc;
#
#    ## Alternatively, make a redirect to a different domain in accordance with
#    ## the file_security_policy in openQA config
#    #return 301 http://$host-files$request_uri;
#}

include vhosts.d/openqa-endpoints.inc;
