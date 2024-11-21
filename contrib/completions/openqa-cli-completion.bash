_openqa_cli_completions() {
    local cur prev subcommands main_options api_options archive_options monitor_options schedule_options
    cur="${COMP_WORDS[COMP_CWORD]}"
    subcommands="api archive monitor schedule"
    main_options="--apibase --apikey --apisecret --help --host --o3 --osd"
    api_options="--json --retries --method --header --links --data-file --data --form --param-file"
    archive_options="--asset-size-limit --name --with-thumbnails"
    monitor_options="--name --poll-interval"
    schedule_options="--monitor --name --poll-interval"

    if [[ ${COMP_CWORD} -eq 1 ]]; then
        COMPREPLY=($(compgen -W "$subcommands" -- "$cur"))
        return 0
    fi
    case "${COMP_WORDS[1]}" in
        api)
	    COMPREPLY=($(compgen -W "$main_options $api_options" -- "$cur"))
            ;;
        archive)
            COMPREPLY=($(compgen -W "$main_options $archive_options" -- "$cur"))
            ;;
        monitor)
            COMPREPLY=($(compgen -W "$main_options $monitor_options" -- "$cur"))
            ;;
        schedule)
            COMPREPLY=($(compgen -W "$main_options $schedule_options" -- "$cur"))
            ;;
        *)
            COMPREPLY=($(compgen -W "$subcommands" -- "$cur"))
            ;;
    esac
}

# Register the completion function for openqa-cli
complete -F _openqa_cli_completions openqa-cli
