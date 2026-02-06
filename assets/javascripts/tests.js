/* jshint esversion: 6 */

const filters = ['todo', 'relevant'];
var is_operator;
var restart_url;
var cancel_url;

function addClassToArray(data, theclass) {
  for (let i = 0; i < data.length; ++i) {
    const el = document.getElementById('job_' + data[i]);
    if (el) el.classList.add(theclass);
  }
}

function removeClassFromArray(data, theclass) {
  for (let i = 0; i < data.length; ++i) {
    const el = document.getElementById('job_' + data[i]);
    if (el) el.classList.remove(theclass);
  }
}

function highlightJobs() {
  const children = JSON.parse(this.dataset.children || '[]');
  const parents = JSON.parse(this.dataset.parents || '[]');
  addClassToArray(children, 'highlight_child');
  addClassToArray(parents, 'highlight_parent');
}

function unhighlightJobs() {
  if (document.activeElement == this) {
    return;
  }
  const children = JSON.parse(this.dataset.children || '[]');
  const parents = JSON.parse(this.dataset.parents || '[]');
  removeClassFromArray(children, 'highlight_child');
  removeClassFromArray(parents, 'highlight_parent');
}

function highlightJobsHtml(children, parents) {
  return (
    ' data-children="[' + children.toString() + ']" data-parents="[' + parents.toString() + ']" class="parent_child"'
  );
}

function renderMediumName(data, type, row) {
  var link = urlWithBase(
    '/tests/overview?build=' +
      encodeURIComponent(row.build) +
      '&distri=' +
      encodeURIComponent(row.distri) +
      '&version=' +
      encodeURIComponent(row.version)
  );
  if (row.group) {
    link += '&groupid=' + encodeURIComponent(row.group);
  }

  var name = "<a href='" + htmlEscape(link) + "'>" + 'Build' + htmlEscape(row.build) + '</a>';
  name += ' of ';
  return name + htmlEscape(row.distri + '-' + row.version + '-' + row.flavor + '.' + row.arch);
}

function renderTestName(data, type, row) {
  if (type !== 'display') {
    return data;
  }

  var html = '';
  if (is_operator) {
    html += '<a class="copy-jobid" href="#" data-jobid="' + row.id + '">';
    html += '<i class="action fa fa-fw fa-copy" title="Copy job id"></i></a>';
    if (row.result !== 'none') {
      // allow to restart finished jobs
      if (!row.clone) {
        const url = restart_url.replace('REPLACEIT', row.id);
        html += ' <a class="restart" href="' + htmlEscape(url) + '">';
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
  html += '<a href="' + urlWithBase('/tests/' + row.id) + '">';
  if (row.result !== 'none') {
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
  html += '<a href="' + urlWithBase('/tests/' + row.id) + '" class="name">' + htmlEscape(data) + '</a>';

  var deps = row.deps;
  if (deps) {
    var dependencyResult = showJobDependency(deps);
    var dependencyHtml = '';
    if (dependencyResult.title !== undefined) {
      dependencyHtml =
        ' <a href="' +
        urlWithBase('/tests/' + row.id) +
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
    html += ' <a href="' + urlWithBase('/tests/' + row.clone) + '">(restarted)</a>';
  }

  return html;
}

function renderTimeAgo(data, type, row, position, notAvailableMessage) {
  var haveData = data && data !== 'Z';
  if (type === 'display') {
    return haveData
      ? '<span title="' + data + '">' + (window.timeago ? window.timeago.format(data) : data) + '</span>'
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
  var prioValueElement = linkElement.parentElement.querySelector('.prio-value');
  var currentPrio = parseInt(prioValueElement.textContent);
  if (Number.isNaN(currentPrio)) {
    addFlash('danger', 'Unable to set prio.');
    return;
  }

  var newPrio = currentPrio + delta;

  const body = new FormData();
  body.append('prio', newPrio);
  fetchWithCSRF(urlWithBase(`/api/v1/jobs/${jobId}/prio`), {method: 'POST', body: body})
    .then(response => {
      return response
        .json()
        .then(json => {
          // Attach the parsed JSON to the response object for further use
          return {response, json};
        })
        .catch(() => {
          // If parsing fails, handle it as a non-JSON response
          throw `Server returned ${response.status}: ${response.statusText}`;
        });
    })
    .then(({response, json}) => {
      if (!response.ok || json.error)
        throw `Server returned ${response.status}: ${response.statusText}\n${json.error || ''}`;
      prioValueElement.textContent = newPrio;
    })
    .catch(error => {
      addFlash('danger', `Unable to set the priority value of job ${jobId}: ${error}`);
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
  return '<a href="' + urlWithBase('/tests/' + row.id) + '">' + html + dependencyResultHtml + '</a>';
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
  ['limit', 'groupid', 'match', 'group_glob', 'not_group_glob', 'comment'].forEach(paramName => {
    ajaxQueryParams.addFirstParam(paramName);
  });
  delete ajaxQueryParams.addFirstParam;
  filters.forEach(filter => {
    const param = pageQueryParams[filter];
    if (Array.isArray(param)) {
      document.getElementById(filter + 'filter').checked = parseInt(param[0]);
    }
  });

  // initialize data tables for running, scheduled and finished jobs
  var runningTable = $('#running').DataTable({
    order: [], // no initial resorting
    ajax: {
      url: urlWithBase('/tests/list_running_ajax'),
      data: ajaxQueryParams,
      dataSrc: function (json) {
        // update heading when JSON is available
        let text = json.data.length + ' jobs are running';
        if (json.max_running_jobs !== undefined && json.max_running_jobs >= 0) {
          text += ' (limited by server config)';
        }
        document.getElementById('running_jobs_heading').textContent = text;
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
      url: urlWithBase('/tests/list_scheduled_ajax'),
      data: ajaxQueryParams,
      dataSrc: function (json) {
        // update heading when JSON is available
        var blockedCount = 0;
        json.data.forEach(row => {
          if (typeof row.blocked_by_id === 'number') {
            ++blockedCount;
          }
        });
        var text = json.data.length + ' scheduled jobs';
        if (blockedCount > 0) {
          text += ' (' + blockedCount + ' blocked by other jobs)';
        }
        document.getElementById('scheduled_jobs_heading').textContent = text;
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
      url: urlWithBase('/tests/list_ajax'),
      data: function () {
        filters.forEach(filter => {
          ajaxQueryParams[filter] = document.getElementById(filter + 'filter').checked ? 1 : 0;
        });
        return ajaxQueryParams;
      },
      dataSrc: function (json) {
        // update heading when JSON is available
        document.getElementById('finished_jobs_heading').textContent = 'Last ' + json.data.length + ' finished jobs';
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
  filters.forEach(filter => {
    document.getElementById(filter + 'filter').onchange = () => table.ajax.reload();
  });

  // initialize filter for result (of finished jobs)
  var finishedJobsResultFilter = document.getElementById('finished-jobs-result-filter');
  // ensure the table is re-drawn when a filter is added/removed
  finishedJobsResultFilter.addEventListener('change', function (event) {
    // update data table
    table.draw();
    // update query params
    var params = parseQueryParams();
    params.resultfilter = $(finishedJobsResultFilter).val();
    updateQueryParams(params);
  });

  // add a handler for the actual filtering
  $.fn.dataTable.ext.search.push(function (settings, data, dataIndex) {
    if (settings.nTable.getAttribute('id') !== 'results') {
      return true; // Do not filter other tables
    }

    var selectedResults = finishedJobsResultFilter.selectedOptions;
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
    $(finishedJobsResultFilter).val(filter).trigger('change');
  }

  document.addEventListener('mouseover', e => {
    const target = e.target.closest('.parent_child');
    if (target) highlightJobs.call(target);
  });
  document.addEventListener('mouseout', e => {
    const target = e.target.closest('.parent_child');
    if (target) unhighlightJobs.call(target);
  });
  document.addEventListener('focusin', e => {
    const target = e.target.closest('.parent_child');
    if (target) highlightJobs.call(target);
  });
  document.addEventListener('focusout', e => {
    const target = e.target.closest('.parent_child');
    if (target) unhighlightJobs.call(target);
  });

  setupTestButtons();
}

function setupTestButtons() {
  document.addEventListener('click', function (event) {
    const restartLink = event.target.closest('.restart');
    if (restartLink) {
      event.preventDefault();
      fetchWithCSRF(restartLink.href, {method: 'POST'})
        .then(response => response.json())
        .then(responseJSON => {
          const flashTarget = document.getElementById('flash-messages-finished-jobs');
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
          const urls = responseJSON.test_url[0];
          Object.entries(urls).forEach(([key, value]) => {
            // Skip to mark the job that is not shown in current page
            const jobElement = document.getElementById('job_' + key);
            if (!jobElement) {
              return;
            }
            const tr = jobElement.closest('tr');
            const td = tr.querySelector('td.test');
            const restart_link_el = td.querySelector('a.restart');
            const i = restart_link_el.querySelector('i');
            i.classList.remove('fa-undo');
            const newLink = document.createElement('a');
            newLink.href = value;
            newLink.title = 'new test';
            newLink.textContent = '(restarted)';
            td.append(' ', newLink);
            restart_link_el.replaceWith(i);
          });
        })
        .catch(error => {
          console.error('Restart failed:', error);
          addFlash('danger', '<strong>Unable to restart job.</strong>');
        });
    }

    const cancelLink = event.target.closest('.cancel');
    if (cancelLink) {
      event.preventDefault();
      fetchWithCSRF(cancelLink.href, {method: 'POST'})
        .then(() => {
          const td = cancelLink.parentElement;
          td.append(' (cancelled)');
          const i = cancelLink.querySelector('i');
          i.classList.remove('fa-times-circle');
          cancelLink.replaceWith(i);
        })
        .catch(error => console.error('Cancel failed:', error));
    }
  });
}

function setupResultButtons() {
  document.querySelectorAll('.restart-result').forEach(el => {
    el.addEventListener('click', function (event) {
      event.preventDefault();
      restartJob(this.href, this.dataset.jobid);
    });
  });
}

function setupLazyLoadingFailedSteps() {
  // lazy-load failed steps when the tooltip is shown
  document.querySelectorAll('.failedmodule').forEach(failedModuleElement => {
    failedModuleElement.addEventListener('show.bs.tooltip', function () {
      // skip if we have already loaded failed steps before
      if (failedModuleElement.hasFailedSteps) {
        return;
      }
      failedModuleElement.hasFailedSteps = true;

      // query failed steps via AJAX
      fetch(failedModuleElement.dataset.bsAsync)
        .then(response => {
          if (!response.ok) throw `Server returned ${response.status}: ${response.statusText}`;
          return response.json();
        })
        .then(fails => {
          const tooltip = bootstrap.Tooltip.getInstance(failedModuleElement);
          // hide tooltip if we have nothing to show
          if (
            typeof fails !== 'object' ||
            fails.first_failed_step === undefined ||
            !Array.isArray(fails.failed_needles) ||
            !fails.failed_needles.length
          ) {
            failedModuleElement.dataset.bsOriginalTitle = '';
            if (tooltip) tooltip.hide();
            return;
          }

          // update href to include the first failed step
          failedModuleElement.href = failedModuleElement.href.replace(/\/1$/, '/' + fails.first_failed_step);

          // show tooltip again with updated data
          const list = fails.failed_needles.map(needle => `<li>${needle}</li>`).join('');
          failedModuleElement.dataset.bsOriginalTitle = `<p>Failed needles:</p><ul>${list}</ul>`;
          if (tooltip) tooltip.show();
        })
        .catch(() => {
          // hide tooltip on error
          failedModuleElement.hasFailedSteps = false;
          const tooltip = bootstrap.Tooltip.getInstance(failedModuleElement);
          if (tooltip) tooltip.hide();
        });
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

document.addEventListener('click', function (event) {
  const target = event.target.closest('.copy-jobid');
  if (target) {
    event.preventDefault();
    navigator.clipboard.writeText(target.dataset.jobid);
  }
});
