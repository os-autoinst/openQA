function setupOverview() {
    setupLazyLoadingFailedSteps();
    $('.cancel')
        .bind("ajax:success", function(event, xhr, status) {
        $(this).text(''); // hide the icon
        var icon = $(this).parents('td').find('.status');
        icon.removeClass('state_scheduled').removeClass('state_running');
        icon.addClass('state_cancelled');
        icon.attr('title', 'Cancelled');
        icon.fadeTo('slow', 0.5).fadeTo('slow', 1.0);
    });
    $('.restart')
        .bind("ajax:success", function(event, xhr, status) {
            if (typeof xhr !== 'object' || !Array.isArray(xhr.result)) {
                addFlash('danger', '<strong>Unable to restart job.</strong>');
                return;
            }
            showJobRestartResults(xhr, undefined, forceJobRestartViaRestartLink.bind(undefined, event.currentTarget));
            var newId = xhr.result[0];
            var oldId = 0;
            $.each(newId, function(key, value) {
                if (!$('.restart[data-jobid="' + key + '"]').length) {
                    return true;
                }
                var restarted = $('.restart[data-jobid="' + key + '"]');
                restarted.text(''); // hide the icon
                var icon = restarted.parents('td').find('.status');
                icon.removeClass('state_done').removeClass('state_cancelled');
                icon.addClass('state_scheduled');
                icon.attr('title', 'Scheduled');
                // remove the result class
                restarted.parents('td').find('.result_passed').removeClass('result_passed');
                restarted.parents('td').find('.result_failed').removeClass('result_failed');
                restarted.parents('td').find('.result_softfailed').removeClass('result_softfailed');

                // If the API call returns a new id, a new job have been created to replace
                // the old one. In other case, the old job is being reused
                if (value) {
                    var link = icon.parents('a');
                    var oldId = restarted.data('jobid');
                    var newUrl = link.attr('href').replace(oldId, value);
                    link.attr('href', newUrl);
                    link.addClass('restarted');
                }

                icon.fadeTo('slow', 0.5).fadeTo('slow', 1.0);
            });
        });

    setupFilterForm();
    $('#filter-todo').prop('checked', false);

    // initialize filter for modules results
    var modulesResultFilter = $('#modules_result');
    modulesResultFilter.chosen({width: "100%"});
    modulesResultFilter.change(function(event) {
        // update query params
        var params = parseQueryParams();
        params.modules_results = modulesResultFilter.val();
    });

    modulesResultFilter.chosen({width: "100%"});

    // find specified results
    var results = {};
    var states = {};
    var modules_results = [];

    var formatFilter = function(filter) {
        return filter.replace(/_/g, ' ');
    };
    var filterLabels = parseFilterArguments(function(key, val) {
        if (key === 'result') {
            results[val] = true;
            return formatFilter(val);
        } else if (key === 'state') {
            states[val] = true;
            return formatFilter(val);
        } else if (key === 'todo') {
            $('#filter-todo').prop('checked', val !== '0');
            return 'TODO';
        } else if (key === 'arch') {
            $('#filter-arch').prop('value', val);
            return val;
        } else if (key === 'machine') {
            $('#filter-machine').prop('value', val);
            return val;
        } else if (key === 'modules') {
            $('#modules').prop('value', val);
            return val;
        } else if (key === 'modules_result') {
            modules_results.push(val);
            modulesResultFilter.val(modules_results).trigger('chosen:updated').trigger('change');
            return formatFilter(val);
        }
    });

    // set enabled/disabled state of checkboxes (according to current filter)
    if(filterLabels.length > 0) {
        $('#filter-results input').each(function(index, element) {
            element.checked = results[element.id.substr(7)];
        });
        $('#filter-states input').each(function(index, element) {
            element.checked = states[element.id.substr(7)];
        });
    }
}
