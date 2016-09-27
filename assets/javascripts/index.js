function setupIndexPage() {
    $('.timeago').timeago();

    setupFilterForm();
    $('#filter-only-tagged').prop('checked', false);

    parseFilterArguments(function(key, val) {
        if (key === 'only_tagged') {
            $('#filter-only-tagged').prop('checked', val !== '0');
            return 'only tagged';
        } else if (key === 'group') {
            $('#filter-group').prop('value', val);
            return "group '" + val + "'";
        } else if (key === 'limit_builds') {
            $('#filter-limit-builds').prop('value', val);
            return val + ' builds per group';
        } else if (key === 'time_limit_days') {
            $('#filter-time-limit-days').prop('value', val);
            return val + ' days old or newer';
        }
    });
}
