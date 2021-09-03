/* jshint esversion: 6 */

var is_operator;
var restart_url;

function addClassToArray(data, theclass) {
  for (i = 0; i < data.length; ++i) $('#job_' + data[i]).addClass(theclass);
}

function removeClassFromArray(data, theclass) {
  for (i = 0; i < data.length; ++i) $('#job_' + data[i]).removeClass(theclass);
}

function highlightJobs() {
  addClassToArray($(this).data('children'), 'highlight_child');
  addClassToArray($(this).data('parents'), 'highlight_parent');
}

function unhighlightJobs(children, parents) {
  if (document.activeElement == this) {
    return;
  }
  removeClassFromArray($(this).data('children'), 'highlight_child');
  removeClassFromArray($(this).data('parents'), 'highlight_parent');
}

function highlightJobsHtml(children, parents) {
  return (
    ' data-children="[' + children.toString() + ']" data-parents="[' + parents.toString() + ']" class="parent_child"'
  );
}

function renderMediumName(data, type, row) {
  var link = '/tests/overview?build=' + row.build + '&distri=' + row.distri + '&version=' + row.version;
  if (row.group) {
    link += '&groupid=' + row.group;
  }

  var name = "<a href='" + link + "'>" + 'Build' + row.build + '</a>';
  name += ' of ';
  return name + row.distri + '-' + row.version + '-' + row.flavor + '.' + row.arch;
}

function renderTestName(data, type, row) {
  if (type !== 'display') {
    return data;
  }

  var html = '';
  if (is_operator) {
    if (row.result) {
      // allow to restart finished jobs
      if (!row.clone) {
        const url = restart_url.replace('REPLACEIT', row.id);
        html += ' <a class="restart" href="' + url + '">';
        html += '<i class="action fa fa-fw fa-undo" title="Restart job"></i></a>';
      } else {
        html += '<i class="fa fa-fw"></i>';
      }
    } else {
      // allow to cancel scheduled and running jobs
      const url = cancel_url.replace('REPLACEIT', row.id);
      html += ' <a class="cancel" href="' + url + '">';
      html += '<i class="action fa fa-fw fa-times-circle-o" title="Cancel job"></i></a>';
    }
  }
  html += '<a href="/tests/' + row.id + '">';
  if (row.result) {
    html += '<i class="status fa fa-circle result_' + row.result + '" title="Done: ' + row.result + '"></i>';
  } else if (row.state === 'scheduled') {
    if (typeof row.blocked_by_id === 'number') {
      html += '<i class="status fa fa-circle state_blocked" title="Blocked"></i>';
    } else {
      html += '<i class="status fa fa-circle state_scheduled" title="Scheduled"></i>';
    }
  } else if (row.state === 'assigned') {
    html += '<i class="status fa fa-circle state_running" title="Assigned"></i>';
  } else {
    html += '<i class="status fa fa-circle state_running" title="Running"></i>';
  }
  html += '</a> ';
  html += '<a href="/tests/' + row.id + '" class="name">' + data + '</a>';

  var deps = row.deps;
  if (deps) {
    var dependencyResult = showJobDependency(deps);
    var dependencyHtml = '';
    if (dependencyResult.title !== undefined) {
      dependencyHtml =
        ' <a href="/tests/' +
        row.id +
        '" title="' +
        dependencyResult.title +
        '"' +
        highlightJobsHtml(dependencyResult['data-children'], dependencyResult['data-parents']) +
        '><i class="fa fa-code-fork"></i></a>';
    }
    html += dependencyHtml;
  }
  if (row.comment_data) {
    html += renderComments(row);
  }
  if (row.clone) {
    html += ' <a href="/tests/' + row.clone + '">(restarted)</a>';
  }

  return html;
}

function renderTimeAgo(data, type, row, position, notAvailableMessage) {
  var haveData = data && data !== 'Z';
  if (type === 'display') {
    return haveData
      ? '<span title="' + data + '">' + jQuery.timeago(data) + '</span>'
      : notAvailableMessage
      ? notAvailableMessage
      : 'not yet';
  }
  return haveData ? data : 'Z-9999-12-31';
}

function renderTimeAgoForFinished(data, type, row, position) {
  return renderTimeAgo(data, type, row, position, 'never started');
}

function renderProgress(data, type, row) {
  var progress = data.modcount > 0 ? Math.round((data.moddone / data.modcount) * 100) : undefined;
  if (type !== 'display') {
    return progress ? progress : 0;
  }
  var progressText = progress === undefined ? row.state : progress + ' %';
  var progressClass = progress === undefined ? 'progress-bar progress-bar-striped active' : 'progress-bar';
  var progressWidth = progress === undefined ? 100 : progress;
  var progressBar =
    '<div class="' +
    progressClass +
    '" role="progressbar" style="width: ' +
    progressWidth +
    '%; min-width: 2em;" aria-valuemax="100" aria-valuemin="0" aria-valuenow="' +
    progress +
    '">' +
    progressText +
    '</div>';
  return '<div class="progress">' + progressBar + '</div>';
}

function renderPriority(data, type, row) {
  if (type !== 'display' || !is_operator) {
    return data;
  }
  var jobId = row.id;
  var decreasePrioLink =
    '<a class="prio-down" data-method="post" href="javascript:void(0);" onclick="decreaseJobPrio(' +
    jobId +
    ', this); return false;"><i class="fa fa-minus-square-o"></i></a>';
  var increasePrioLink =
    '<a class="prio-up" data-method="post" href="javascript:void(0);" onclick="increaseJobPrio(' +
    jobId +
    ', this); return false;"><i class="fa fa-plus-square-o"></i></a>';
  var text = ' <span class="prio-value">' + data + '</span> ';
  return decreasePrioLink + text + increasePrioLink;
}

// define functions to increase/decrease a job priority and update the UI accordingly
// note: These functions are also used by the info panel on the test details page.
function increaseJobPrio(jobId, linkElement) {
  changeJobPrio(jobId, 10, linkElement);
}

function decreaseJobPrio(jobId, linkElement) {
  changeJobPrio(jobId, -10, linkElement);
}

function changeJobPrio(jobId, delta, linkElement) {
  var prioValueElement = $(linkElement).parent().find('.prio-value');
  var currentPrio = parseInt(prioValueElement.text());
  if (Number.isNaN(currentPrio)) {
    addFlash('danger', 'Unable to set prio.');
    return;
  }

  var newPrio = currentPrio + delta;
  $.ajax({
    url: '/api/v1/jobs/' + jobId + '/prio?prio=' + newPrio,
    method: 'POST',
    success: function (result) {
      prioValueElement.text(newPrio);
    },
    error: function (xhr, ajaxOptions, thrownError) {
      addFlash('danger', 'Unable to set the priority of job ' + jobId + '.');
    }
  });
}

function renderTestSummary(data) {
  var html = (data.passed || 0) + "<i class='fa module_passed fa-star' title='modules passed'></i>";
  if (data.softfailed)
    html += ' ' + data.softfailed + "<i class='fa module_softfailed fa-star-half' title='modules with warnings'></i>";
  if (data.failed) html += ' ' + data.failed + "<i class='fa module_failed fa-star' title='modules failed'></i>";
  if (data.none) html += ' ' + data.none + "<i class='fa module_none fa-ban' title='modules skipped'></i>";
  if (data.skipped)
    html +=
      ' ' + data.skipped + "<i class='fa module_skipped fa-angle-double-right' title='modules externally skipped'></i>";
  return html;
}

function renderTestResult(data, type, row) {
  if (type !== 'display') {
    return parseInt(data.passed) * 10000 + parseInt(data.softfailed) * 100 + parseInt(data.failed);
  }

  var html = '';
  if (row.state === 'done') {
    html += renderTestSummary(data);
  } else if (row.state === 'cancelled') {
    html += "<i class='fa fa-times' title='canceled'></i>";
  }
  var dependencyResultHtml = '';
  if (row.deps.has_parents) {
    dependencyResultHtml = row.deps.parents_ok
      ? " <i class='fa fa-link' title='dependency passed'></i>"
      : " <i class='fa fa-unlink' title='dependency failed'></i>";
  }
  return '<a href="/tests/' + row.id + '">' + html + dependencyResultHtml + '</a>';
}

function renderTestLists() {
  // determine params for AJAX queries
  var pageQueryParams = parseQueryParams();
  var ajaxQueryParams = {};
  ajaxQueryParams.addFirstParam = function (paramName) {
    var paramValues = pageQueryParams[paramName];
    if (paramValues && paramValues.length > 0) {
      this[paramName] = paramValues[0];
    }
  };
  jQuery.each(['limit', 'groupid', 'match'], function (index, paramName) {
    ajaxQueryParams.addFirstParam(paramName);
  });
  delete ajaxQueryParams.addFirstParam;

  // initialize data tables for running, scheduled and finished jobs
  var runningTable = $('#running').DataTable({
    order: [], // no initial resorting
    ajax: {
      url: '/tests/list_running_ajax',
      data: ajaxQueryParams,
      dataSrc: function (json) {
        // update heading when JSON is available
        $('#running_jobs_heading').text(json.data.length + ' jobs are running');
        return json.data;
      }
    },
    columns: [{data: 'name'}, {data: 'test'}, {data: 'progress'}, {data: 'testtime'}],
    columnDefs: [
      {
        targets: 0,
        className: 'name',
        render: renderMediumName
      },
      {
        targets: 1,
        className: 'test',
        render: renderTestName
      },
      {
        targets: 2,
        render: renderProgress
      },
      {
        targets: 3,
        className: 'time',
        render: renderTimeAgo
      }
    ]
  });
  var scheduledTable = $('#scheduled').DataTable({
    order: [], // no initial resorting
    ajax: {
      url: '/tests/list_scheduled_ajax',
      data: ajaxQueryParams,
      dataSrc: function (json) {
        // update heading when JSON is available
        var blockedCount = 0;
        jQuery.each(json.data, function (index, row) {
          if (typeof row.blocked_by_id === 'number') {
            ++blockedCount;
          }
        });
        var text = json.data.length + ' scheduled jobs';
        if (blockedCount > 0) {
          text += ' (' + blockedCount + ' blocked by other jobs)';
        }
        $('#scheduled_jobs_heading').text(text);
        return json.data;
      }
    },
    columns: [{data: 'name'}, {data: 'test'}, {data: 'prio'}, {data: 'testtime'}],
    columnDefs: [
      {
        targets: 0,
        className: 'name',
        render: renderMediumName
      },
      {
        targets: 1,
        className: 'test',
        render: renderTestName
      },
      {
        targets: 2,
        render: renderPriority
      },
      {
        targets: 3,
        className: 'time',
        render: renderTimeAgo
      }
    ]
  });
  var table = $('#results').DataTable({
    lengthMenu: [
      [10, 25, 50],
      [10, 25, 50]
    ],
    ajax: {
      url: '/tests/list_ajax',
      data: function () {
        ajaxQueryParams.relevant = $('#relevantfilter').prop('checked');
        return ajaxQueryParams;
      },
      dataSrc: function (json) {
        // update heading when JSON is available
        $('#finished_jobs_heading').text('Last ' + json.data.length + ' finished jobs');
        return json.data;
      }
    },
    order: [], // no initial resorting
    columns: [{data: 'name'}, {data: 'test'}, {data: 'result_stats'}, {data: 'testtime'}],
    columnDefs: [
      {
        targets: 0,
        className: 'name',
        render: renderMediumName
      },
      {
        targets: 1,
        className: 'test',
        render: renderTestName
      },
      {
        targets: 2,
        render: renderTestResult
      },
      {
        targets: 3,
        className: 'time',
        render: renderTimeAgoForFinished
      }
    ]
  });

  // register event listener to the two range filtering inputs to redraw on input
  $('#relevantfilter').change(function () {
    $('#relevantbox').css('color', 'cyan');
    table.ajax.reload(function () {
      $('#relevantbox').css('color', 'inherit');
    });
  });

  // initialize filter for result (of finished jobs) as chosen
  var finishedJobsResultFilter = $('#finished-jobs-result-filter');
  finishedJobsResultFilter.chosen();
  // ensure the table is re-drawn when a filter is added/removed
  finishedJobsResultFilter.change(function (event) {
    // update data table
    table.draw();
    // update query params
    var params = parseQueryParams();
    params.resultfilter = finishedJobsResultFilter.val();
    updateQueryParams(params);
  });

  // add a handler for the actual filtering
  $.fn.dataTable.ext.search.push(function (settings, data, dataIndex) {
    var selectedResults = finishedJobsResultFilter.find('option:selected');
    // don't apply filter if no result is selected
    if (!selectedResults.length) {
      return true;
    }
    // check whether actual result is contained by list of results to be filtered
    data = table.row(dataIndex).data();
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
  $(document).on('click', '.restart', function (event) {
    event.preventDefault();
    var restartLink = this;
    $.post(restartLink.href).done(function (data, res, xhr) {
      var responseJSON = xhr.responseJSON;
      var flashTarget = $('#flash-messages-finished-jobs');
      if (typeof responseJSON !== 'object' || !Array.isArray(responseJSON.test_url)) {
        addFlash('danger', '<strong>Unable to restart job.</strong>', flashTarget);
        return;
      }
      showJobRestartResults(
        responseJSON,
        undefined,
        forceJobRestartViaRestartLink.bind(undefined, restartLink),
        flashTarget
      );
      var urls = responseJSON.test_url[0];
      $.each(urls, function (key, value) {
        // Skip to mark the job that is not shown in current page
        if (!$('#job_' + key).length) {
          return true;
        }
        var td = $('#job_' + key)
          .closest('tr')
          .children('td.test');
        var restart_link = td.children('a.restart');
        var i = restart_link.find('i').removeClass('fa-undo');
        td.append(' <a href="' + value + '" title="new test">(restarted)</a>');
        restart_link.replaceWith(i);
      });
    });
  });

  $(document).on('click', '.cancel', function (event) {
    event.preventDefault();
    var cancel_link = $(this);
    var test = $(this).parent('td');
    $.post(cancel_link.attr('href')).done(function (data) {
      $(test).append(' (cancelled)');
    });
    var i = $(this).find('i').removeClass('fa-times-circle');
    $(this).replaceWith(i);
  });
}

function setupResultButtons() {
  $('#restart-result').click(function (event) {
    event.preventDefault();
    restartJob($(this).attr('href'), $(this).data('jobid'));
    // prevent posting twice by clicking #restart-result
    return false;
  });
}

function setupLazyLoadingFailedSteps() {
  // lazy-load failed steps when the tooltip is shown
  $('.failedmodule').on('show.bs.tooltip', function () {
    // skip if we have already loaded failed steps before
    if (this.hasFailedSteps) {
      return;
    }
    this.hasFailedSteps = true;

    // query failed steps via AJAX
    var failedModuleElement = $(this);
    $.getJSON(failedModuleElement.data('async'), function (fails) {
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
      $.each(fails.failed_needles, function (i, needle) {
        newTitle += '<li>' + needle + '</li>';
      });
      newTitle += '</ul>';
      failedModuleElement.attr('data-original-title', newTitle);

      // update existing tooltip
      if (failedModuleElement.next('.tooltip').length) {
        failedModuleElement.tooltip('show');
      }
    }).fail(function () {
      this.hasFailedSteps = false;
    });
  });
}

function showJobDependency(deps) {
  var parents = deps.parents;
  var children = deps.children;
  var depsTooltip = [];
  var result = {};
  depsTooltip.quantify = function (quantity, singular, plural) {
    if (quantity) {
      this.push([quantity, quantity === 1 ? singular : plural].join(' '));
    }
  };
  depsTooltip.quantify(parents.Chained.length, 'chained parent', 'chained parents');
  depsTooltip.quantify(parents['Directly chained'].length, 'directly chained parent', 'directly chained parents');
  depsTooltip.quantify(parents.Parallel.length, 'parallel parent', 'parallel parents');
  depsTooltip.quantify(children.Chained.length, 'chained child', 'chained children');
  depsTooltip.quantify(children['Directly chained'].length, 'directly chained child', 'directly chained children');
  depsTooltip.quantify(children.Parallel.length, 'parallel child', 'parallel children');
  if (depsTooltip.length) {
    var childrenToHighlight = children.Parallel.concat(children.Chained, children['Directly chained']);
    var parentsToHighlight = parents.Parallel.concat(parents.Chained, parents['Directly chained']);
    result.title = depsTooltip.join(', ');
    result['data-children'] = childrenToHighlight;
    result['data-parents'] = parentsToHighlight;
  }
  return result;
}
