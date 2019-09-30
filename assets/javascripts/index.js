function setupIndexPage() {
    $('.timeago').timeago();

    setupFilterForm({preventLoadingIndication: true});

    var filterFullScreenCheckBox = $('#filter-fullscreen');
    var showTagsCheckBox = $('#filter-show-tags');
    var onlyTaggedCheckBox = $('#filter-only-tagged');
    var defaultExpanedCheckBox = $('#filter-default-expanded');
    filterFullScreenCheckBox.prop('checked', false);
    showTagsCheckBox.prop('checked', false);
    onlyTaggedCheckBox.prop('checked', false);
    onlyTaggedCheckBox.on('change', function() {
        var checked = onlyTaggedCheckBox.prop('checked');
        if (checked) {
            showTagsCheckBox.prop('checked', true);
        }
        showTagsCheckBox.prop('disabled', checked);
    });
    defaultExpanedCheckBox.prop('checked', false);

    parseFilterArguments(function(key, val) {
        if (key === 'show_tags') {
            showTagsCheckBox.prop('checked', val !== '0');
            return 'show tags';
        } else if (key === 'only_tagged') {
            onlyTaggedCheckBox.prop('checked', val !== '0');
            onlyTaggedCheckBox.trigger('change');
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
        } else if (key === 'fullscreen') {
          filterFullScreenCheckBox.prop('checked', val !== '0');
          return 'fullscreen';
        } else if (key === 'default_expanded') {
            defaultExpanedCheckBox.prop('checked', val !== '0');
            return 'expanded';
        }
    });

    setupBuildResults();
    toggleFullscreenMode(filterFullScreenCheckBox.is(':checked'));
}

function setupBuildResults(queryParams) {
    var buildResultsElement = $('#build-results');
    var loadingElement = $('#build-results-loading');
    var filterForm = $('#filter-form');
    var filterFormApplyButton = $('#filter-apply-button');

    loadingElement.show();
    buildResultsElement.html('');
    filterFormApplyButton.prop('disabled', true);
    window.updatingBuildResults = true;

    var showBuildResults = function(buildResults) {
        loadingElement.hide();
        buildResultsElement.html(buildResults);
        alignBuildLabels();
        filterFormApplyButton.prop('disabled', false);
        window.updatingBuildResults = false;
    };

    // query build results via AJAX using parameters from filter form
    $.ajax({
        url: buildResultsElement.data('build-results-url'),
        data: queryParams ? queryParams : window.location.search.substr(1),
        success: function(response) {
            showBuildResults(response);
            window.buildResultStatus = 'success';
        },
        error: function(xhr, ajaxOptions, thrownError) {
            showBuildResults('<div class="alert alert-danger" role="alert">Unable to fetch build results.</div>');
            window.buildResultStatus = 'error: ' + thrownError;
        }
    });

    // prevent page reload when submitting filter form (when we load build results via AJAX anyways)
    filterForm.submit(function(event) {
        if (!window.updatingBuildResults) {
            var queryParams = filterForm.serialize();
            setupBuildResults(queryParams);
            history.replaceState({} , document.title, window.location.pathname + '?' + queryParams);
        }
        toggleFullscreenMode($('#filter-fullscreen').is(':checked'));
        event.preventDefault();
    });
}
