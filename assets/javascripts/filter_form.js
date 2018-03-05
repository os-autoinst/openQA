function setupFilterForm() {
    // make filter form expandable
    $('#filter-panel .card-header').on('click', function() {
        $('#filter-panel .card-body').toggle(200);
        if($('#filter-panel').hasClass('filter-panel-bottom')) {
            $('html,body').animate({
                scrollTop: $(document).height()
            });
        }
    });

    $('#filter-panel .help_popover').on('click', function(event) {
        event.stopPropagation();
    });

    $('#filter-form').on('submit', function(event) {
        if($('#filter-form').serialize() !== window.location.search.substring(1)) {
            // show progress indication
            $('#filter-form').hide();
            $('#filter-panel .card-body').append('<span id="filter-progress"><i class="fa fa-cog fa-spin fa-2x fa-fw"></i> <span>Applying filter…</span></span>');
        }
    });
}

function parseFilterArguments(paramHandler) {
    var varPairs = window.location.search.substring(1).split('&');
    var filterLabels = [];
    for (var j = 0; j < varPairs.length; ++j) {
        var pair = varPairs[j].split('=');
        if(pair.length > 1) {
            var key = decodeURIComponent(pair[0].replace(/\+/g, '%20'));
            var val = decodeURIComponent(pair[1].replace(/\+/g, '%20'));
            if(val.length < 1) {
                continue;
            }
            var filterLabel = paramHandler(key, val);
            if(filterLabel) {
                filterLabels.push(filterLabel);
            } else {
                var input = $('<input/>');
                input.attr('value', val);
                input.attr('name', key);
                input.attr('hidden', true);
                $('#filter-form').append(input);
            }
        }
    }
    if(filterLabels.length > 0) {
        $('#filter-panel .card-header').find('span').text('current: ' + filterLabels.join(', '));
    }
    return filterLabels;
}
