function setupOverview() {
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
	    var oldId = 0;
	    var newId = xhr['result'][0];

	    $(this).text(''); // hide the icon
	    var icon = $(this).parents('td').find('.status');
	    icon.removeClass('state_done').removeClass('state_cancelled');
	    icon.addClass('state_scheduled');
	    icon.attr('title', 'Scheduled');
            // remove the result class
	    $(this).parents('td').find('.result_passed').removeClass('result_passed');
	    $(this).parents('td').find('.result_failed').removeClass('result_failed');
            $(this).parents('td').find('.result_softfail').removeClass('result_softfail');

	    // If the API call returns a new id, a new job have been created to replace
	    // the old one. In other case, the old job is being reused
	    if (newId) {
		var link = icon.parents('a');
		var oldId = $(this).data('jobid');
		var newUrl = link.attr('href').replace(oldId, newId);
		link.attr('href', newUrl);
	    }

	    icon.fadeTo('slow', 0.5).fadeTo('slow', 1.0);

	});

    // ensure TODO is false by default because the Browser auto remembers previous state
    $('#filter-todo').prop('checked', false);
    
    // find specified results
    var varPairs = window.location.search.substring(1).split('&');
    var results = {};
    var states = {};

    var currentFilter = [];
    var formatFilter = function(filter) {
        return filter.replace(/_/g, ' ');
    };

    for (var j = 0; j < varPairs.length; ++j) {
        var pair = varPairs[j].split('=');
        if(pair.length > 1) {
            var key = pair[0];
            var val = pair[1];
            if(val.length < 1) {
                continue;
            }
            if (key === 'result') {
                results[val] = true;
                currentFilter.push(formatFilter(val));
            } else if (key === 'state') {
                states[val] = true;
                currentFilter.push(formatFilter(val));
            } else if (key === 'todo') {
                $('#filter-todo').prop('checked', val !== '0');
                currentFilter.push('TODO');
            } else if (key === 'arch') {
                $('#filter-arch').prop('value', val);
                currentFilter.push(val);
            } else {
                var input = $('<input/>');
                input.attr('value', val);
                input.attr('name', key);
                input.attr('hidden', true);
                $('#filter-form').append(input);
            }
        }
    }

    // make filter form expandable
    var filterHeading = $('#filter-panel .panel-heading');
    filterHeading.on('click', function() {
        $('#filter-panel .panel-body').toggle(200);
    });

    // set enabled/disabled state of checkboxes (according to current filter)
    if(currentFilter.length > 0) {
        $('#filter-results input').each(function(index, element) {
            element.checked = results[element.id.substr(7)];
        });
        $('#filter-states input').each(function(index, element) {
            element.checked = states[element.id.substr(7)];
        });
        filterHeading.find('span').text('current: ' + currentFilter.join(', '));
    }

    // don't add empty architecture to query parameters
    $('#filter-form').on('submit', function() {
        var archFilterElement = $('#filter-arch');
        if(archFilterElement.val() === '') {
            archFilterElement.remove();
        }
    });
}

