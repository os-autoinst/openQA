function setupIndexPage() {
    $('.timeago').timeago();

    setupFilterForm();
    $('#filter-show-tags').prop('checked', false);
    $('#filter-only-tagged').prop('checked', false);

    $('#filter-only-tagged').on('change', function() {
        var checked = $('#filter-only-tagged').prop('checked');
        var showTagsElement = $('#filter-show-tags');
        if (checked) {
            showTagsElement.prop('checked', true);
        }
        showTagsElement.prop('disabled', checked);
    });

    parseFilterArguments(function(key, val) {
        if (key === 'show_tags') {
            $('#filter-show-tags').prop('checked', val !== '0');
            return 'show tags';
        } else if (key === 'only_tagged') {
            $('#filter-only-tagged').prop('checked', val !== '0');
            $('#filter-only-tagged').trigger('change');
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
