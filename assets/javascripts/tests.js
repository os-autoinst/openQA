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
    if (document.activeElement == this) {
        return;
    }
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
            if (!row.clone) {
                var url = restart_url.replace('REPLACEIT', row.id);
                html += ' <a class="restart"';
                html += ' href="' + url + '">';
                html += '<i class="action fa fa-fw fa-redo" title="Restart Job"></i></a>';
            } else {
                html += '<i class="fa fa-fw"></i>';
            }
        }
        html += '<a href="/tests/' + row.id + '">';
        html += '<i class="status fa fa-circle result_' + row.result + '" title="Done: ' + row.result + '"></i>';
        html += '</a> ';
        // the name
        html += '<a href="/tests/' + row.id + '" class="name">' + data + '</a>';

        var parents = row.deps.parents;
        var children = row.deps.children;
        var depsTooltip = [];
        depsTooltip.quantify = function(quandity, singular, plural) {
            if (quandity) {
                this.push([quandity, quandity === 1 ? singular : plural].join(' '));
            }
        }
        depsTooltip.quantify(parents.Chained.length, 'chained parent', 'chained parents');
        depsTooltip.quantify(parents.Parallel.length, 'parallel parent', 'parallel parents');
        depsTooltip.quantify(children.Chained.length, 'chained child', 'chained children');
        depsTooltip.quantify(children.Parallel.length, 'parallel child', 'parallel children');
        if (depsTooltip.length) {
            html += ' <a href="/tests/' + row.id + '" title="' + depsTooltip.join(', ') + '"'
            + highlightJobsHtml(children.Parallel.concat(children.Chained), parents.Parallel.concat(parents.Chained))
            + '><i class="fa fa-code-branch"></i></a>';
        }
        if (row.comment_count) {
            html += ' <a href="/tests/' + row.id + '#comments"><i class="test-label label_comment fa fa-comment" title="' + row.comment_count + (row.comment_count != 1 ? ' comments' : ' comment') + ' available"'
            + '></i></a>';
        }

        if (row.clone)
            html += ' <a href="/tests/' + row.clone + '">(restarted)</a>';

        return html;
    } else {
        return data;
    }
}

function renderTimeAgo(data, type, row) {
    if(type === 'display') {
        return data ? ('<span title="' + data + '">' + jQuery.timeago(data) + '</span>') : 'not finished yet';
    } else {
        return data ? data : 0;
    }
}

function renderTestResult( data, type, row ) {
    if (type === 'display') {
        var html = '';
        if (row['state'] === 'done') {
            html += data['passed'] + "<i class='fa module_passed fa-star' title='modules passed'></i>";
            if (data['softfailed']) {
                html += " " + data['softfailed'] + "<i class='fa module_softfailed fa-star-half' title='modules with warnings'></i>";
            }
            if (data['failed']) {
                html += " " + data['failed'] + "<i class='far module_failed fa-star' title='modules failed'></i>";
            }
            if (data['none']) {
                html += " " + data['none'] + "<i class='fa module_none fa-ban' title='modules skipped'></i>";
            }
        }
        if (row['state'] === 'cancelled') {
            html += "<i class='fa fa-times' title='canceled'></i>";
        }
        if (row['deps']['parents']['Parallel'].length + row['deps']['parents']['Chained'].length > 0) {
            if (row['result'] === 'skipped' ||
                row['result'] === 'parallel_failed') {
                html += " <i class='fa fa-unlink' title='dependency failed'></i>";
            }
            else {
                html += " <i class='fa fa-link' title='dependency passed'></i>";
            }
        }
        return '<a href="/tests/' + row['id'] + '">' + html + '</a>';
    } else {
        return (parseInt(data['passed']) * 10000) + (parseInt(data['softfailed']) * 100) + parseInt(data['failed']);
    }
}

function renderTestsList(jobs) {

    var table = $('#results').DataTable( {
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
                  var link = '/tests/overview?build=' + row['build'] + '&distri=' + row['distri'] + '&version=' + row['version'];
                  if (row['group'])
                      link += '&groupid=' + row['group'];

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
              className: "time",
              "render": renderTimeAgo
            },
            { targets: 2,
              "render": renderTestResult
            }
        ]
    } );

    // register event listener to the two range filtering inputs to redraw on input
    $('#relevantfilter').change( function() {
        $('#relevantbox').css('color', 'cyan');
        table.ajax.reload(function() {
            $('#relevantbox').css('color', 'inherit');
        } );
    } );

    // initialize filter for result (of finished jobs) as chosen
    var finishedJobsResultFilter = $('#finished-jobs-result-filter');
    finishedJobsResultFilter.chosen();
    // ensure the table is re-drawn when a filter is added/removed
    finishedJobsResultFilter.change(function(event) {
        // update data table
        table.draw();
        // update query params
        var params = parseQueryParams();
        params.resultfilter = finishedJobsResultFilter.val();
        updateQueryParams(params);
    });
    // add a handler for the actual filtering
    $.fn.dataTable.ext.search.push(function(settings, data, dataIndex) {
        var selectedResults = finishedJobsResultFilter.find('option:selected');
        // don't apply filter if no result is selected
        if (!selectedResults.length) {
            return true;
        }
        // check whether actual result is contained by list of results to be filtered
        var data = table.row(dataIndex).data();
        if (!data) {
            return false;
        }
        var result = data.result;
        if (!result) {
            return false;
        }
        for (var i = 0; i != selectedResults.length; ++i) {
            if (selectedResults[i].value.toLowerCase() === result) {
                return true;
            }
        }
        return false;
    });
    // apply filter from query params
    var filter = parseQueryParams().resultfilter;
    if (filter) {
        finishedJobsResultFilter.val(filter).trigger('chosen:updated').trigger('change');
    }

    $(document).on('mouseover', '.parent_child', highlightJobs);
    $(document).on('mouseout', '.parent_child', unhighlightJobs);
    $(document).on('focusin', '.parent_child', highlightJobs);
    $(document).on('focusout', '.parent_child', unhighlightJobs);

    setupTestButtons();
}

function setupTestButtons() {
    $(document).on("click", '.restart', function(event) {
        event.preventDefault();
        $.post($(this).attr("href")).done( function( data, res, xhr ) {
            var urls = xhr.responseJSON.test_url[0];
            $.each( urls , function( key, value ) {
                // Skip to mark the job that is not shown in current page
                if (!$('#job_' + key).length) { return true };
                var td = $('#job_' + key).closest("tr").children('td.test');
                var restart_link = td.children('a.restart');
                var i = restart_link.find('i').removeClass('fa-redo');
                td.append(' <a href="' + value + '" title="new test">(restarted)</a>');
                restart_link.replaceWith(i);
            });
        });
    });

    $(document).on('click', '.cancel', function(event) {
        event.preventDefault();
        var cancel_link = $(this);
        var test = $(this).parent('td');
        $.post(cancel_link.attr("href")).done( function( data ) { $(test).append(' (cancelled)'); });
        var i = $(this).find('i').removeClass('fa-times-circle');
        $(this).replaceWith(i);
    });
}

function setupResultButtons() {
    $( '#restart-result' ).click( function(event) {
        event.preventDefault();
        var testid = $(this).data('jobid');
        $.post($(this).attr("href")).done( function( data, res, xhr ) {
            var new_url = xhr.responseJSON.test_url[0][testid];
            window.location.replace(new_url);
        });
        // Add this to prevent twice post by clicking #restart-result
        return false;
    });
}

function setupLazyLoadingFailedSteps() {
    // lazy-load failed steps when the tooltip is shown
    $('.failedmodule').on('show.bs.tooltip', function() {
        // skip if we have already loaded failed steps before
        if (this.hasFailedSteps) {
            return;
        }
        this.hasFailedSteps = true;

        // query failed steps via AJAX
        var failedModuleElement = $(this);
        $.getJSON(failedModuleElement.data('async'), function(fails) {
            // adjust href
            var newHref = failedModuleElement.attr('href').replace(/\/1$/, '/' + fails.first_failed_step);
            failedModuleElement.attr('href', newHref);

            // hide tooltip if we have nothing to show
            if (!fails.failed_needles.length) {
                failedModuleElement.attr('data-original-title', '');
                failedModuleElement.tooltip('hide');
                return;
            }

            // update data for tooltip
            var newTitle = '<p>Failed needles:</p><ul>';
            $.each(fails.failed_needles, function(i, needle) {
                newTitle += '<li>' + needle + '</li>';
            });
            newTitle += '</ul>';
            failedModuleElement.attr('data-original-title', newTitle);

            // update existing tooltip
            if (failedModuleElement.next('.tooltip').length) {
                failedModuleElement.tooltip('show');
            }
        }).fail(function() {
            this.hasFailedSteps = false;
        });
    });
}

function setupRunningAndScheduledTables() {
    $('#scheduled, #running').DataTable({
        order: [],
        columnDefs: [{
            targets: 0,
            className: "name"
        },
        {
            targets: "time",
            render: function ( data, type, row ) {
                if (type === 'display') {
                    return data !== '0Z' ? jQuery.timeago(new Date(data)) : 'not yet';
                } else {
                    return data;
                }
            }
        }],
    });
}
