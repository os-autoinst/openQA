function setupJobNextPrevious() {
  if (document.querySelector('#job_next_previous_table > tbody')) {
    return; // skip if already initialized
  }

  var params = parseQueryParams();

  var setPage = function (json) {
    // Seems an issue in case of displayStart is not an integer multiple of the pageLength
    // Calculate and start the page with current job
    var current_index = json.data
      .map(function (n) {
        return n.iscurrent;
      })
      .indexOf(1);
    var page = Math.min(Math.max(0, Math.floor(current_index / table.page.len())), table.page.info().pages);
    table.page(page).draw('page');
  };

  var tableElement = document.getElementById('job_next_previous_table');
  var table = $(tableElement).DataTable({
    ajax: {
      url: tableElement.dataset.ajaxUrl,
      data: function (d) {
        if (typeof params.previous_limit != 'undefined') {
          d.previous_limit = params.previous_limit.toString();
        }
        if (typeof params.next_limit != 'undefined') {
          d.next_limit = params.next_limit.toString();
        }
      }
    },
    paging: true,
    ordering: false,
    deferRender: true,
    columns: [{width: '5%'}, {data: 'result'}, {data: 'build'}, {data: 'finished'}],
    processing: false,
    order: false,
    columnDefs: [
      {targets: 0, render: renderMarks},
      {
        targets: 1,
        createdCell: function (td, cellData, rowData, row, col) {
          $(td).attr('id', 'res_' + rowData.id);
        },
        render: renderJobResults
      },
      {targets: 2, render: renderBuild},
      {targets: 3, render: renderFinishTime}
    ],
    initComplete: function (settings, json) {
      setPage(json);
    }
  });
  tableElement.addEventListener('draw.dt', function () {
    setupLazyLoadingFailedSteps();
    document.querySelectorAll('[data-bs-toggle="tooltip"]').forEach(e => new bootstrap.Tooltip(e));
  });
}

function renderMarks(data, type, row) {
  var html = '<span class="badge badge-info float-right" title="';
  if (row.iscurrent == 1 && row.islatest == 1) {
    html += 'Current & Latest job">C&amp;L</span>';
  } else if (row.iscurrent == 1) {
    html += 'Current job">C</span>';
  } else if (row.islatest == 1) {
    html += 'Latest job">L</span>';
  }
  return html;
}

function renderJobResults(data, type, row) {
  var html = '';
  // job status
  html += '<span id="res-' + row.id + '">';
  html += '<a href="' + urlWithBase('/tests/' + row.id) + '">';
  if (row.result == 'none' && (row.state == 'running' || row.state == 'scheduled')) {
    html += '<i class="status fa fa-circle state_' + row.state + '" title="' + row.state + '"></i>';
  } else {
    html += '<i class="status fa fa-circle result_' + row.result + '" title="Done: ' + row.result + '"></i>';
  }
  html += '</a>\n</span>';
  // job failed modules
  var limit = 25;
  var count = 0;
  for (var i in row.failedmodules) {
    if (count++) {
      var more = row.failedmodules.length - count + 1;
      if (more > 0 && limit < 12) {
        html += '<span title="';
        for (var j = i; j < row.failedmodules.length; j++) {
          html += '- ' + htmlEscape(row.failedmodules[j]) + '\n';
        }
        html += '">+' + more + '</span>';
        break;
      }
    }
    var async_url = urlWithBase('/tests/' + row.id + '/modules/' + htmlEscape(row.failedmodules[i]) + '/fails');
    html += '<a data-bs-toggle="tooltip" data-placement="top" ';
    html += 'data-container="#res_' + row.id + '" ';
    html += 'data-async="' + async_url + '" ';
    html += "title=\"<i class='fa fa-sync fa-spin fa-2x fa-fw'></i><span class='sr-only'>Loading...</span>\"";
    html += 'class="failedmodule" ';
    html += 'href="' + urlWithBase('/tests/' + row.id + '#step/' + htmlEscape(row.failedmodules[i]) + '/1') + '">';
    html += '<span title="' + htmlEscape(row.failedmodules[i]) + '">' + htmlEscape(row.failedmodules[i]) + '</span>';
    html += '</a>';
    if (row.failedmodules[i].length > limit) {
      limit -= limit;
    } else {
      limit -= row.failedmodules[i].length + 2;
    }
  }

  // job bugs, comments and label
  if (row.comment_data) {
    html += renderComments(row);
  }
  return html;
}

function renderBuild(data, type, row) {
  const link = urlWithBase('/tests/overview?distri=' + row.distri + '&version=' + row.version + '&build=' + row.build);
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
  document.getElementById('next-and-prev-tab-link').addEventListener('show.bs.tab', setupJobNextPrevious);
  if (window.location.hash === '#next_previous') {
    setupJobNextPrevious();
  }
}
