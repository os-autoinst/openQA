#!/usr/bin/env zsh

_openqa_cli_completions() {
    local curcontext="$curcontext" state line
    typeset -A opt_args
    local -a subcommands
    local -a main_options
    local -a output_options
    local -a api_options
    local -a archive_options
    local -a monitor_options
    local -a schedule_options
    subcommands=("api" "archive" "monitor" "schedule")
    main_options=(
        '--apibase[Base URL for the API]'
        '--apikey[API key for authentication]'
        '--apisecret[API secret for authentication]'
        '--help[Show help message]'
        '--host[Target host, defaults to http://localhost]'
        '--o3[Set target host to https://openqa.opensuse.org]'
        '--osd[Set target host to http://openqa.suse.de]'
    )
    output_options=(
        '--pretty[Pretty print JSON content]'
        '--quiet[Do not print error messages to STDERR]'
        '--verbose[Print HTTP response headers]'
    )
    api_options=(
        '--json[Request content is JSON]'
        '--retries[Retry up to the specified value on some error]'
        '--method[HTTP method to use, defaults to GET]'
        '--header[One or more additional HTTP headers]'
        '--links[Print pagination links to STDERR]'
        '--data-file[Load content to send with request from file]'
        '--data[Content to send with request]'
        '--form[Turn JSON object into form parameters]'
        '--param-file[Load content of params from files instead of from command line arguments.]'       
    )
    archive_options=(
        '--asset-size-limit[Asset size limit in bytes]'
        '--name[Name of this client, used by openQA to identify different clients via User-Agent header, defaults to "openqa-cli"]'
        '--with-thumbnails[Download thumbnails as well]'
    )
    monitor_options=(
        '--name[Name of this client, used by openQA to identify different clients via User-Agent header, defaults to "openqa-cli"]'
        '--poll-interval[Specifies the poll interval in seconds]'
    )
    schedule_options=(
        '--monitor[it until all jobs are done/cancelled and return non-zero exit code if at least on job has not passed/softfailed]'
        '--name[Name of this client, used by openQA to identify different clients via User-Agent header, defaults to "openqa-cli"]'
        '--poll-interval[Specifies the poll interval in seconds]'
    )
    # Complete with subcommands
    if (( CURRENT == 2 )); then
         _describe 'subcommand' subcommands
    else
        case "$words[2]" in
            api)
                _arguments '*:option:->options' $main_options $api_options
                ;;
            archive)
                _arguments '*:option:->options' $main_options $archive_options
                ;;
            monitor)
                _arguments '*:option:->options' $main_options $archive_options
            ;;
            schedule)
                _arguments '*:option:->options' $main_options $archive_options
                ;;
        *)
            _values 'subcommand' api archive monitor schedule
            ;;
        esac
    fi
}

# Register the completion function for openqa-cli
compdef _openqa_cli_completions openqa-cli
