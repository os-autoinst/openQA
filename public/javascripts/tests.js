var is_operator;
var restart_url;

function addClassToArray(data, theclass) {
    for (i = 0; i < data.length; ++i) $("#job_" + data[i]).addClass(theclass);
}

function removeClassFromArray(data, theclass) {
    for (i = 0; i < data.length; ++i) $("#job_" + data[i]).removeClass(theclass);
}

function highlightJobs () {
    addClassToArray($(this).data('children'), 'highlight_child');
    addClassToArray($(this).data('parents'), 'highlight_parent');
}

function unhighlightJobs( children, parents ) {
    removeClassFromArray($(this).data('children'), 'highlight_child');
    removeClassFromArray($(this).data('parents'), 'highlight_parent');
}

function highlightJobsHtml (children, parents) {
    return ' data-children="[' + children.toString() + ']" data-parents="[' + parents.toString() + ']" class="parent_child"';
}


function renderTestName ( data, type, row ) {
    if (type === 'display') {
        var html = '';
	if (is_operator) {
	    if (!row['clone']) {
            var url = restart_url.replace('REPLACEIT', row['id']);
            html += ' <a class="restart"';
            html += ' href="' + url + '">';
		html += '<i class="action fa fa-fw fa-repeat" title="Restart Job"></i></a>';
            } else {
		html += '<i class="fa fa-fw"></i>';
	    }
	}
        html += '<a href="/tests/' + row['id'] + '">';
        html += '<i class="status fa fa-circle result_' + row['result'] + '" title="Done: ' + row['result'] + '"></i>';
        html += '</a> ';
        // the name
        html += '<a href="/tests/' + row['id'] + '" class="name">' + data + '</a>';

        var deps = '';
        if (row['deps']['parents']['Chained'].length) {
            if (deps != '') deps += ', ';
            if (row['deps']['parents']['Chained'].length == 1) {
                deps += '1 Chained parent';
            }
            else {
                deps += row['deps']['parents']['Chained'].length + ' Chained parents';
            }
        }
        if (row['deps']['parents']['Parallel'].length) {
            if (deps != '') deps += ', ';
            if (row['deps']['parents']['Parallel'].length == 1) {
                deps += '1 Parallel parent';
            }
            else {
                deps += row['deps']['parents']['Parallel'].length + ' Parallel parents';
            }
        }
        if (row['deps']['children']['Chained'].length) {
            if (deps != '') deps += ', ';
            if (row['deps']['children']['Chained'].length == 1) {
                deps += '1 Chained child';
            }
            else {
                deps += row['deps']['children']['Chained'].length + ' Chained children';
            }
        }
        if (row['deps']['children']['Parallel'].length) {
            if (deps != '') deps += ', ';
            if (row['deps']['children']['Parallel'].length == 1) {
                deps += '1 Parallel child';
            }
            else {
                deps += row['deps']['children']['Parallel'].length + ' Parallel children';
            }
        }

        if (deps != '') {
                html += ' <a href="/tests/' + row['id'] + '" title="' + deps + '"' +
                highlightJobsHtml(row['deps']['children']['Parallel'].concat(row['deps']['children']['Chained']),
                                    row['deps']['parents']['Parallel'].concat(row['deps']['parents']['Chained'])) +
                '><i class="fa fa-code-fork"></i></a>';
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
        "dom": "<'row'<'col-sm-3'l><'#toolbar'><'col-sm-4'f>>" +
            "<'row'<'col-sm-12'tr>>" +
            "<'row'<'col-sm-6'i><'col-sm-6'p>>",
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
        ]
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

    $(document).on('mouseover', '.parent_child', highlightJobs);
    $(document).on('mouseout', '.parent_child', unhighlightJobs);

    $(document).on("click", '.restart', function(event) {
	event.preventDefault();
        var restart_link = $(this);
        var link = $(this).parent('td');
        $.post(restart_link.attr("href")).done( function( data, res, xhr ) {
	    link.append(' <a href="' + xhr.responseJSON.test_url + '" title="new test">(restarted)</a>');
	});
        var i = $(this).find('i').removeClass('fa-repeat');
	$(this).replaceWith(i);
    });

    $(document).on('click', '.cancel', function(event) {
	event.preventDefault();
        var cancel_link = $(this);
        var test = $(this).parent('td');
        $.post(cancel_link.attr("href")).done( function( data ) { $(test).append(' (cancelled)'); });
	var i = $(this).find('i').removeClass('fa-times-circle-o');
	$(this).replaceWith(i);
    });
}

function setupResultButtons() {
    $( '#restart-result' ).click( function(event) {
        event.preventDefault();
        $.post($(this).attr("href")).done( function( data, res, xhr ) {
            window.location.replace(xhr.responseJSON.test_url);
        });
    });
}
