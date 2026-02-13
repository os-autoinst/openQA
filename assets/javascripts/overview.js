/* jshint esversion: 6 */

function overviewRowDisplay(expand) {
  return expand ? 'table-row' : 'none';
}

function toggleParallelChildren(expand, parentJobID) {
  const display = overviewRowDisplay(expand);
  Array.from(document.getElementsByClassName('parallel-child-of-' + parentJobID)).forEach(childRow => {
    childRow.style.display = display;
  });
}

function considerChildrenChanged(expanded, parentElement) {
  Array.from(parentElement.getElementsByClassName('toggle-parallel-children')).forEach(toggleLink => {
    toggleLink.dataset.expanded = expanded ? '1' : '';
  });
}

function toggleAllParallelChildren(expand, table) {
  const display = overviewRowDisplay(expand);
  Array.from(table.getElementsByClassName('parallel-child')).forEach(childRow => {
    childRow.style.display = display;
  });
  considerChildrenChanged(expand, table);
}

function hasOnlyOkChildren(table, parentID) {
  const sel = '.parallel-child-of-' + parentID + window.overviewParallelChildrenCollapsableResultsSel;
  return table.querySelector(sel) === null;
}

function collapseOkParallelChildren() {
  Array.from(document.getElementsByClassName('parallel-parent')).forEach(parentRow => {
    const parentIDs = parentRow.dataset.parallelParents.split(',');
    if (parentIDs.find(hasOnlyOkChildren.bind(this, parentRow.parentElement))) {
      parentIDs.forEach(toggleParallelChildren.bind(this, false));
      considerChildrenChanged(false, parentRow);
    }
  });
}

function appendParallelChildren(parentRow, parentJobID) {
  Array.from(document.getElementsByClassName('parallel-child-of-' + parentJobID)).forEach(childRow => {
    parentRow.insertAdjacentElement('afterend', childRow);
  });
}

function ensureParallelParentsComeFirst() {
  Array.from(document.getElementsByClassName('parallel-parent')).forEach(parentRow => {
    parentRow.dataset.parallelParents.split(',').forEach(appendParallelChildren.bind(undefined, parentRow));
  });
}

function showToggleLinkForParallelParents(relatedRow, relatedTable, resElement, parallelChildren) {
  if (!Array.isArray(parallelChildren)) {
    return false;
  }
  const jobIDMatch = (resElement.id || '').match(/\d+/);
  if (!jobIDMatch) {
    return false;
  }
  const jobID = jobIDMatch[0];
  if (!parallelChildren.find(childID => relatedTable.querySelector('tr:not(.parallel-parent) #res-' + childID))) {
    return false; // no children present in same table which aren't already parents as well
  }
  const testNameCell = relatedRow.firstElementChild;
  const existingToggleLink = testNameCell.getElementsByClassName('toggle-parallel-children');
  if (existingToggleLink.length) {
    relatedRow.dataset.parallelParents += ',' + jobID;
    existingToggleLink[0].dataset.ids += ',' + jobID;
    return true;
  }
  const toggleLink = document.createElement('a');
  toggleLink.className = 'toggle-parallel-children btn btn-outline-primary fa fa-clone';
  relatedRow.classList.add('parallel-parent');
  relatedRow.dataset.parallelParents = jobID;
  toggleLink.title = 'Show/hide parallel children';
  toggleLink.dataset.ids = jobID;
  toggleLink.dataset.expanded = '1';
  toggleLink.onclick = function () {
    const dataset = this.dataset;
    const expand = (dataset.expanded = dataset.expanded ? '' : '1');
    dataset.ids.split(',').forEach(toggleParallelChildren.bind(this, expand));
    return false;
  };
  testNameCell.appendChild(toggleLink);
  const heading = relatedTable.parentElement.previousElementSibling;
  if (heading.previousElementSibling.classList.contains('btn')) {
    return true;
  }
  const collapseAllButton = document.createElement('a');
  collapseAllButton.className = 'collapse-all-button btn btn-outline-primary btn-sm fa fa-compress';
  collapseAllButton.title = 'Collapse all parallel children';
  collapseAllButton.onclick = toggleAllParallelChildren.bind(this, false, relatedTable);
  heading.insertAdjacentElement('beforebegin', collapseAllButton);
  const expandAllButton = document.createElement('a');
  expandAllButton.className = 'expand-all-button btn btn-outline-primary btn-sm fa fa-expand';
  expandAllButton.title = 'Expand all parallel children';
  expandAllButton.onclick = toggleAllParallelChildren.bind(this, true, relatedTable);
  heading.insertAdjacentElement('beforebegin', expandAllButton);
  return true;
}

function initCollapsedParallelChildren(relatedRow, relatedTable, parallelParents) {
  if (!Array.isArray(parallelParents) || parallelParents.length !== 1) {
    return false;
  }
  if (relatedTable.querySelector('#res-' + parallelParents[0])) {
    relatedRow.classList.add('parallel-child');
    parallelParents.forEach(parentID => relatedRow.classList.add('parallel-child-of-' + parentID));
  }
}

function stackParallelChildren(depElement, dependencyInfo) {
  const relatedRow = depElement.parentElement.parentElement;
  const relatedTable = relatedRow.parentElement;
  const resElement = depElement.previousElementSibling;
  showToggleLinkForParallelParents(relatedRow, relatedTable, resElement, dependencyInfo.children.Parallel) ||
    initCollapsedParallelChildren(relatedRow, relatedTable, dependencyInfo.parents.Parallel);
}

function setupOverview() {
  setupLazyLoadingFailedSteps();
  document.querySelectorAll('.timeago').forEach(el => {
    if (window.timeago && typeof window.timeago.format === 'function') {
      const date = el.getAttribute('title') || el.getAttribute('datetime');
      if (date) {
        el.textContent = window.timeago.format(date);
      }
    }
  });
  document.querySelectorAll('.cancel').forEach(el => {
    el.addEventListener('ajax:success', function () {
      this.textContent = ''; // hide the icon
      const icon = this.closest('td').querySelector('.status');
      if (icon) {
        icon.classList.remove('state_scheduled', 'state_running');
        icon.classList.add('state_cancelled');
        icon.title = 'Cancelled';
        icon.style.opacity = 0.5;
        setTimeout(() => (icon.style.opacity = 1.0), 500);
      }
    });
  });
  document.querySelectorAll('.restart').forEach(el => {
    el.addEventListener('ajax:success', function (event) {
      const xhr = event.detail[0];
      if (typeof xhr !== 'object' || !Array.isArray(xhr.result)) {
        addFlash('danger', '<strong>Unable to restart job.</strong>');
        return;
      }
      showJobRestartResults(xhr, undefined, forceJobRestartViaRestartLink.bind(undefined, event.currentTarget));
      const newIdMap = xhr.result[0];
      Object.entries(newIdMap).forEach(([key, value]) => {
        const restarted = document.querySelector('.restart[data-jobid="' + key + '"]');
        if (!restarted) {
          return;
        }
        restarted.textContent = ''; // hide the icon
        const td = restarted.closest('td');
        const icon = td.querySelector('.status');
        if (icon) {
          icon.classList.remove('state_done', 'state_cancelled');
          icon.classList.add('state_scheduled');
          icon.title = 'Scheduled';
        }
        // remove the result class
        td.querySelectorAll('.result_passed, .result_failed, .result_softfailed').forEach(el => {
          el.classList.remove('result_passed', 'result_failed', 'result_softfailed');
        });

        // If the API call returns a new id, a new job have been created to replace
        // the old one. In other case, the old job is being reused
        if (value && icon) {
          const link = icon.closest('a');
          const oldId = restarted.dataset.jobid;
          const newUrl = link.getAttribute('href').replace(oldId, value);
          link.setAttribute('href', newUrl);
          link.classList.add('restarted');
        }

        if (icon) {
          icon.style.opacity = 0.5;
          setTimeout(() => (icon.style.opacity = 1.0), 500);
        }
      });
    });
  });
  var dependencies = document.getElementsByClassName('dependency');
  for (let i = 0; i < dependencies.length; i++) {
    const depElement = dependencies[i];
    var depInfo = depElement.dataset;
    var deps = JSON.parse(depInfo.deps);
    var dependencyResult = showJobDependency(deps);
    if (dependencyResult.title === undefined) {
      continue;
    }
    var elementIClass = 'fa fa-code-fork';
    var elementATitle = dependencyResult.title;
    if (deps.has_parents) {
      var str = parseInt(deps.parents_ok) ? 'passed' : 'failed';
      elementIClass += ' result_' + str;
      elementATitle += '\ndependency ' + str;
    }
    var elementA = document.createElement('a');
    elementA.href = urlWithBase('/tests/' + depInfo.jobid + '#dependencies');
    elementA.title = elementATitle;
    elementA.className = 'parents_children';
    elementA.dataset.childrenDeps = '[' + dependencyResult['data-children'].toString() + ']';
    elementA.dataset.parentsDeps = '[' + dependencyResult['data-parents'].toString() + ']';
    var elementI = document.createElement('i');
    elementI.setAttribute('class', elementIClass);
    elementA.appendChild(elementI);
    depElement.appendChild(elementA);
    stackParallelChildren(depElement, deps);
  }
  ensureParallelParentsComeFirst();
  collapseOkParallelChildren();

  setupFilterForm();
  const form = document.getElementById('filter-form');
  form.todo = false;

  // initialize filter for modules results
  const modulesResultFilter = document.getElementById('modules_result');
  if (modulesResultFilter) {
    modulesResultFilter.addEventListener('change', function (event) {
      // update query params
      var params = parseQueryParams();
      params.modules_results = Array.from(modulesResultFilter.selectedOptions).map(opt => opt.value);
    });
  }

  // find specified results
  const flags = {result: {}, state: {}};
  const modulesResults = [];
  const formatFilter = filter => {
    return filter.replace(/_/g, ' ');
  };
  const filterLabels = parseFilterArguments((key, val) => {
    if (key === 'result' || key === 'state') {
      flags[key][val] = true;
      return formatFilter(val);
    } else if (key === 'todo') {
      const todoCheck = document.getElementById('filter-todo');
      if (todoCheck) todoCheck.checked = val !== '0';
      return 'TODO';
    } else if (key === 'modules_result') {
      modulesResults.push(val);
      if (modulesResultFilter) {
        Array.from(modulesResultFilter.options).forEach(opt => {
          if (opt.value === val) opt.selected = true;
        });
        modulesResultFilter.dispatchEvent(new Event('change'));
      }
      return formatFilter(val);
    } else {
      const input = document.getElementById('filter-' + key.replace(/_/g, '-')) || form.elements[key];
      if (input && input.value !== undefined) {
        input.value += input.value.length > 0 ? `,${val}` : val;
        return val;
      }
    }
  });

  // set enabled/disabled state of checkboxes (according to current filter)
  if (filterLabels.length > 0) {
    setCheckboxStatesForFlags('filter-results', flags.result);
    setCheckboxStatesForFlags('filter-states', flags.state);
  }

  const parentChild = document.getElementsByClassName('parents_children');
  for (let i = 0; i < parentChild.length; i++) {
    parentChild[i].addEventListener('mouseover', highlightDeps);
    parentChild[i].addEventListener('mouseout', unhighlightDeps);
  }
}

function setCheckboxStatesForFlags(containerId, flags) {
  Array.from(document.getElementById(containerId).getElementsByTagName('input')).forEach(e => {
    e.checked = flags[e.id.substr(7)];
  });
}

function highlightDeps() {
  var parentData = JSON.parse(this.dataset.parentsDeps);
  var childData = JSON.parse(this.dataset.childrenDeps);
  changeClassOfDependencyJob(parentData, 'highlight_parent', true);
  changeClassOfDependencyJob(childData, 'highlight_child', true);
}

function unhighlightDeps() {
  var parentData = JSON.parse(this.dataset.parentsDeps);
  var childData = JSON.parse(this.dataset.childrenDeps);
  changeClassOfDependencyJob(parentData, 'highlight_parent', false);
  changeClassOfDependencyJob(childData, 'highlight_child', false);
}

function changeClassOfDependencyJob(array, className, add) {
  for (var i = 0; i < array.length; i++) {
    const ele = document.getElementsByName('jobid_td_' + array[i])[0];
    if (ele === undefined) {
      continue;
    }
    const classList = ele.parentNode.classList;
    add ? classList.add(className) : classList.remove(className);
  }
}

function showAddCommentsDialog() {
  const modal = (window.addCommentsModal = new bootstrap.Modal('#add-comments-modal'));
  modal.show();
}

function restartJobsWithComment(btn) {
  const form = btn.form;
  const text = form.elements.text.value;
  const jobs = btn.dataset.jobs
    .split(',')
    .map(Number)
    .filter(n => !isNaN(n));
  const apiUrl = btn.dataset.url;
  if (!text.length) {
    return window.alert("The comment text mustn't be empty.");
  }

  const progressIndication = document.getElementById('add-comments-progress-indication');
  const controls = document.getElementById('add-comments-controls');
  progressIndication.style.display = 'flex';
  controls.style.display = 'none';
  restartJob(apiUrl, jobs, text).finally(() => {
    progressIndication.style.display = 'none';
    controls.style.display = 'inline';
    window.addCommentsModal.hide();
  });
}

function addComments(btn) {
  const form = btn.form;
  const text = form.elements.text.value;
  const apiUrl = btn.dataset.url;
  if (!text.length) {
    return window.alert("The comment text mustn't be empty.");
  }
  const progressIndication = document.getElementById('add-comments-progress-indication');
  const controls = document.getElementById('add-comments-controls');
  progressIndication.style.display = 'flex';
  controls.style.display = 'none';
  const done = () => {
    progressIndication.style.display = 'none';
    controls.style.display = 'inline';
    window.addCommentsModal.hide();
  };
  fetchWithCSRF(apiUrl, {method: 'POST', body: new FormData(form)})
    .then(response => {
      if (!response.ok) throw `Server returned ${response.status}: ${response.statusText}`;
      addFlash(
        'info',
        'The comments have been created. <a href="javascript: location.reload()">Reload</a> the page to show changes.'
      );
      done();
    })
    .catch(error => {
      addFlash('danger', `The comments could not be added: ${error}`);
      done();
    });
}
