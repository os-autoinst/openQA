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
    for (var j = 0; j < varPairs.length; ++j) {
        var pair = varPairs[j].split('=');
        if(pair.length > 1) {
            var key = pair[0];
            var val = pair[1];
            if (key === 'result') {
                results[val] = true;
            } else if (key === 'state') {
                states[val] = true;
            } else if (key === 'todo') {
                $('#filter-todo').prop('checked', val !== '0');
            } else if (key === 'arch') {
                $('#filter-arch').prop('value', val);
            } else {
                var input = $('<input/>');
                input.attr('value', val);
                input.attr('name', key);
                input.attr('hidden', true);
                $('#filter-form').append(input);
            }
        }
    }
    
    // set enabled/disabled state of checkboxes (according to current filter)
    var resultNames = ['none', 'skipped', 'obsoleted', 'parallel_failed', 'parallel_restarted', 'user_cancelled', 'user_restarted', 'passed', 'incomplete', 'softfailed', 'failed', 'scheduled', 'running', 'none', 'unknown'];
    for(var i = 0; i < resultNames.length; ++i) {
        var result = resultNames[i];
        $('#filter-' + result).prop('checked', results[result]);
    }
    
    var stateNames = ['scheduled', 'running', 'cancelled', 'waiting', 'done', 'uploading'];
    for(var i = 0; i < stateNames.length; ++i) {
        var state = stateNames[i];
        $('#filter-' + state).prop('checked', states[state]);
    }
}

