# Define rate limiting maps
# Map request method to a rate limiting key for webui_limit (empty for modifying requests, $binary_remote_addr otherwise)
map $request_method $webui_limit_key {
    ~^(POST|PUT|PATCH|DELETE)$ "";
    default $binary_remote_addr;
}
# Map request method to a rate limiting key for webui_light_limit ($binary_remote_addr for modifying requests or lightweight routes, empty otherwise)
map "$request_method:$uri" $webui_light_limit_key {
    ~^(POST|PUT|PATCH|DELETE): $binary_remote_addr;
    ~^[^:]+:/api/v1/jobs/[0-9]+/(mutex|barrier|artefact) $binary_remote_addr;
    default "";
}

# Define rate limiting zones for endpoints of the openQA web application (10 MB zone allows ~160,000 IPs)
# low limit for heavy routes (like search and investigation)
limit_req_zone $binary_remote_addr zone=webui_heavy_limit:10m rate=10r/s;
# high limit for lightweight routes and all for modifying requests (very frequently used by workers, tests and scripts)
limit_req_zone $webui_light_limit_key zone=webui_light_limit:10m rate=250r/s;
# medium limit per second for all other routes
limit_req_zone $webui_limit_key zone=webui_limit:10m rate=50r/s;
