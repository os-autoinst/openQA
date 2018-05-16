function setupJobNextPrevious() {
    var table = $('#job_next_previous_table').DataTable({
        ajax: {
            url: $('#job_next_previous_table').data('ajax-url'),
            data: function ( d ) {
                d.limit = $('#limit_num').val();
            }
        },
        paging: true,
        ordering : false,
        deferRender: true,
        columns: [
            {width: "5%"},
            {data: "result"},
            {data: "build"},
            {data: "finished"}
        ],
        processing: false,
        order: false,
        columnDefs: [
            {targets: 0, render: renderMarks},
            {
                targets: 1,
                createdCell: function (td, cellData, rowData, row, col) {
                    $(td).attr("id", 'res_' + rowData.id);
                },
                render: renderJobResults,
            },
            {targets: 2, render: renderBuild},
            {targets: 3, render: renderFinishTime},
        ]
    });
    $('#job_next_previous_table').on('draw.dt', function (){
        setupLazyLoadingFailedSteps();
        $('[data-toggle="tooltip"]').tooltip({html: true});
    });
}

function renderMarks(data, type, row) {
    var html = '<span class="badge badge-info float-right" title="';
    if (row.iscurrent == 1 && row.islatest == 1) {
        html += 'Current & Latest job">C&amp;L</span>';
    }
    else if (row.iscurrent == 1) {
        html += 'Current job">C</span>';
    }
    else if (row.islatest == 1) {
        html += 'Latest job">L</span>';
    }
    return html;
}

function renderJobResults(data, type, row) {
    var html = '';
    // job status
    html += '<span id="res-' + row.id + '">';
    html += '<a href="/tests/' + row.id + '">';
    if (row.result == 'none' && (row.state == 'running' || row.state == 'scheduled')) {
        html += '<i class="status fa fa-circle state_' + row.state + '" title="' + row.state + '"></i>';
    } else {
        html += '<i class="status fa fa-circle result_' + row.result + '" title="Done: ' + row.result + '"></i>';
    }
    html += "</a>\n</span>";
    // job failed modules
    var limit = 25;
    var count = 0;
    for (var i in row.failedmodules) {
        if (count++) {
            var more = row.failedmodules.length - count + 1;
            if (more > 0 && limit < 12) {
                html += '+' + more;
                break;
            }
        }
        var async_url = '/tests/' + row.id + '/modules/' + row.failedmodules[i] + '/fails';
        html += '<a data-toggle="tooltip" data-placement="top" ';
        html += 'data-container="#res_' + row.id + '" ';
        html += 'data-async="' + async_url + '" ';
        html += 'title="<i class=\'fa fa-sync fa-spin fa-2x fa-fw\'></i><span class=\'sr-only\'>Loading...</span>"';
        html += 'class="failedmodule" ';
        html += 'href="/tests/' + row.id + '#step/' + row.failedmodules[i] + '/1">';
        html += '<span title="' + row.failedmodules[i] + '">' + row.failedmodules[i] + '</span>';
        html += '</a>';
        if (row.failedmodules[i].length > limit) {
            limit -= limit;
        }
        else {
            limit -= row.failedmodules[i].length + 2;
        }
    }

    // job bugs, comments and label
    if (row.bugs != []) {
        for (var i in row.bugs) {
            html += '<span id="bug-' + row.id + '">';
            html += '<a href="' + row.bug_urls[i] + '">';
            html += '<i class="test-label ' + row.bug_icons[i] + '" title="Bug referenced: ' + row.bugs[i] + '"></i>';
            html += '</a></span>';
        }
    }
    if (row.label != null) {
        html += '<span id="test-label-' + row.id + '">';
        html += '<i class="test-label label_' + row.label + ' fa fa-bookmark" title="Label: ' + row.label + '"></i>';
        html += '</span>';
    }
    else if (row.comments != null) {
        html += '<span id="comment-' + row.id + '">';
        html += row.comment_icon;
        html += '</span>';
    }
    return html;
}

function renderBuild(data, type, row) {
    var link = '/tests/overview?distri=' + row.distri + '&version=' + row.version + '&build=' + row.build;
    return "<a href='" + link + "'>" + row.build + '</a>';
}

function renderFinishTime(data, type, row) {
    var html = '';
    if (data != null) {
        html += '<abbr class="timeago" title="' + data + '">' + jQuery.timeago(data) + ' </abbr>';
        html += '( ' + row.duration + ' )';
    } else {
        if (row.state == 'running' || row.state == 'scheduled') {
            html += 'Not yet: ' + row.state;
        }
    }
    return html;
}

function triggerJobNextPrevious() {
    $('a[data-toggle="tab"]').on("show.bs.tab", function(e) {
        if (e.target.hash === '#next_previous') {
            if (!$('#job_next_previous_table > tbody').length) {
                setupJobNextPrevious();
            }
        }
    });
    // Navigate or refresh #next_previous to show datatable
    var hash = window.location.hash;
    if (hash == "#next_previous") {
        if (!$('#job_next_previous_table > tbody').length) {
            setupJobNextPrevious();
        }
    }

    $('#limit_num').on('change', function() {
        if ($.fn.dataTable.isDataTable('#job_next_previous_table')) {
            var table = $('#job_next_previous_table').DataTable();
            table.destroy();
        }
        setupJobNextPrevious();
    });
}
