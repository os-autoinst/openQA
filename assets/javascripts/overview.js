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
    $('[data-toggle="tooltip"]').tooltip({html: true});
}

