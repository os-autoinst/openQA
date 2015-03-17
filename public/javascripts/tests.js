var is_operator;
var restart_url;

function renderTestName ( data, type, row ) {
    if (type === 'display') {
	var html = '<span class="result_' + row['result'] + '">';
	html += '<a href="/tests/' + row['id'] + '">';
	html += '<i class="status fa fa-circle" title="Done: ' + row['result'] + '"></i>';
	if (is_operator && !row['clone']) {
	    var url = restart_url.replace('REPLACEIT', row['id']);
            html += ' <a data-method="POST" data-remote="true" class="restart"';
	    html += ' href="' + url + '">';
            html += '<i class="action fa fa-repeat" title="Restart Job"></i></a>';
	}
        html += '</a> ';
	// the name
	html += '<a href="/tests/' + row['id'] + '" class="name">' + data + '</a>';
	html += '</span>';

        var deps = '';
        if (row['deps']['parents']['Chained'].length) {
            if (deps != '') deps += ', ';
            if (row['deps']['parents']['Chained'].length == 1) {
                deps += '1 Chained parent';
            }
            else {
                deps += row['deps']['parents']['Chained'].length + ' Chained parents'
            }
        }
        if (row['deps']['parents']['Parallel'].length) {
            if (deps != '') deps += ', ';
            if (row['deps']['parents']['Parallel'].length == 1) {
                deps += '1 Parallel parent';
            }
            else {
                deps += row['deps']['parents']['Parallel'].length + ' Parallel parents'
            }
        }
        if (row['deps']['children']['Chained'].length) {
            if (deps != '') deps += ', ';
            if (row['deps']['children']['Chained'].length == 1) {
                deps += '1 Chained child';
            }
            else {
                deps += row['deps']['children']['Chained'].length + ' Chained children'
            }
        }
        if (row['deps']['children']['Parallel'].length) {
            if (deps != '') deps += ', ';
            if (row['deps']['children']['Parallel'].length == 1) {
                deps += '1 Parallel child';
            }
            else {
                deps += row['deps']['children']['Parallel'].length + ' Parallel children'
            }
        }

        if (deps != '') {
                html += ' <a href="/tests/' + row['id'] + '" title="' + deps + '"' +
                '><i class="fa fa-plus"></i></a>';
        }

	if (row['clone'])
            html += ' <a href="/tests/' + row['clone'] + '">(restarted)</a>';

        return html;
    } else {
	return data;
    }
}

function renderTestResult( data, type, row ) {
    if (type === 'display') {
	var html = '';
	if (row['state'] === 'done') {
	    html += data['passed'] + "<i class='fa module_passed fa-star' title='modules passed'></i>";
	    if (data['dents']) {
		html +=  " " + data['dents'] + "<i class='fa module_softfail fa-star-half-empty' title='modules with warnings'></i> ";
	    }
	    if (data['failed']) {
		html +=  " " + data['failed'] + "<i class='fa module_failed fa-star-o' title='modules failed'></i> ";
	    }
	    if (data['none']) {
		html +=  " " + data['none'] + "<i class='fa module_none fa-ban' title='modules skipped'></i> ";
	    }
	}
	if (row['state'] === 'cancelled') {
	    html += "<i class='fa fa-times' title='canceled'></i>";
	}
	if (row['deps']['parents']['Parallel'].length + row['deps']['parents']['Chained'].length > 0) {
	    if (row['result'] === 'skipped' ||
		row['result'] === 'parallel_failed') {
		html += "<i class='fa fa-chain-broken' title='dependency failed'></i>";
	    }
	    else {
		html += "<i class='fa fa-link' title='dependency passed'></i>";
	    }
	}
        return '<a href="/tests/' + row['id'] + '">' + html + '</a>';
    } else {
	return (parseInt(data['passed']) * 10000) + (parseInt(data['dents']) * 100) + parseInt(data['failed']);
    }
}

function renderTestsList(jobs) {

    var table = $('#results').DataTable( {
	"dom": 'l<"#toolbar">frtip',
	"lengthMenu": [[10, 25, 50], [10, 25, 50]],
	"ajax": {
	    "url": "/tests/list_ajax",
	    "type": "POST", // we use POST as the URLs can get long
	    "data": function(d) {
		var ret = {
		    "relevant": $('#relevantfilter').prop('checked')
		};
		if (jobs != null) {
		    ret['jobs'] = jobs;
		    ret['initial'] = 1;
		}
		// reset for reload
		jobs = null;
		return ret;
	    }
	},
	// no initial resorting
	"order": [],
	"columns": [
	    { "data": "name" },
	    { "data": "test" },
	    { "data": "result_stats" },
	    { "data": "testtime" },
	],
	"columnDefs": [
	    { targets: 0,
	      className: "name",
	      "render": function ( data, type, row ) {
		  var link = '/tests/overview?build=' + row['build'];
		  if (row['group'])
		      link += '&groupid=' + row['group'];
		  else
		      link += '&distri=' + row['distri'] + '&version=' + row['version'];

		  var name = "<a href='" + link + "'>" + 'Build' + row['build'] + '</a>';
		  name += " of ";
		  return name + row['distri'] + "-" + row['version'] + "-" + row['flavor'] + "." + row['arch'];
	      }
	    },
	    { targets: 1,
	      className: "test",
	      "render": renderTestName
	    },
	    { targets: 3,
	      "render": function ( data, type, row ) {
		  if (type === 'display')
		      return jQuery.timeago(data + " UTC");
		  else
		      return data;
	      }
	    },
	    { targets: 2,
	      "render": renderTestResult
	    }
	],
    } );
    $("#relevantbox").detach().appendTo('#toolbar');
    $('#relevantbox').css('display', 'inherit');
    // Event listener to the two range filtering inputs to redraw on input
    $('#relevantfilter').change( function() {
	$('#relevantbox').css('color', 'cyan');
        table.ajax.reload(function() {
	    $('#relevantbox').css('color', 'inherit');
	} );
    } );
    $(document).on("click", '.restart', function() {
	var restart_link = $(this);
	var link = $(this).parent('span').find('.name');
	$.post(restart_link.attr("href")).done( function( data ) { $(link).append(' (restarted)'); });
	$(this).html('');
    });
};
