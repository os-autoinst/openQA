/* jshint esversion: 6 */

function setupOverview () {
  setupLazyLoadingFailedSteps();
  $('.timeago').timeago();
  $('.cancel')
    .bind('ajax:success', function (event, xhr, status) {
      $(this).text(''); // hide the icon
      const icon = $(this).parents('td').find('.status');
      icon.removeClass('state_scheduled').removeClass('state_running');
      icon.addClass('state_cancelled');
      icon.attr('title', 'Cancelled');
      icon.fadeTo('slow', 0.5).fadeTo('slow', 1.0);
    });
  $('.restart')
    .bind('ajax:success', function (event, xhr, status) {
      if (typeof xhr !== 'object' || !Array.isArray(xhr.result)) {
        addFlash('danger', '<strong>Unable to restart job.</strong>');
        return;
      }
      showJobRestartResults(xhr, undefined, forceJobRestartViaRestartLink.bind(undefined, event.currentTarget));
      const newId = xhr.result[0];
      const oldId = 0;
      $.each(newId, function (key, value) {
        if (!$('.restart[data-jobid="' + key + '"]').length) {
          return true;
        }
        const restarted = $('.restart[data-jobid="' + key + '"]');
        restarted.text(''); // hide the icon
        const icon = restarted.parents('td').find('.status');
        icon.removeClass('state_done').removeClass('state_cancelled');
        icon.addClass('state_scheduled');
        icon.attr('title', 'Scheduled');
        // remove the result class
        restarted.parents('td').find('.result_passed').removeClass('result_passed');
        restarted.parents('td').find('.result_failed').removeClass('result_failed');
        restarted.parents('td').find('.result_softfailed').removeClass('result_softfailed');

        // If the API call returns a new id, a new job have been created to replace
        // the old one. In other case, the old job is being reused
        if (value) {
          const link = icon.parents('a');
          const oldId = restarted.data('jobid');
          const newUrl = link.attr('href').replace(oldId, value);
          link.attr('href', newUrl);
          link.addClass('restarted');
        }

        icon.fadeTo('slow', 0.5).fadeTo('slow', 1.0);
      });
    });
  const dependencies = document.getElementsByClassName('dependency');
  for (let i = 0; i < dependencies.length; i++) {
    const depObject = dependencies[i];
    const depInfo = dependencies[i].dataset;
    const deps = JSON.parse(depInfo.deps);
    const dependencyResult = showJobDependency(deps);
    if (dependencyResult.title === undefined) { continue; }
    let elementIClass = 'fa fa-code-branch';
    let elementATitle = dependencyResult.title;
    if (deps.has_parents) {
      const str = parseInt(deps.parents_ok) ? 'passed' : 'failed';
      elementIClass += ' result_' + str;
      elementATitle += '\ndependency ' + str;
    }
    const elementA = document.createElement('a');
    elementA.href = '/tests/' + depInfo.jobid + '#dependencies';
    elementA.title = elementATitle;
    elementA.className = 'parents_children';
    elementA.dataset.childrenDeps = '[' + dependencyResult['data-children'].toString() + ']';
    elementA.dataset.parentsDeps = '[' + dependencyResult['data-parents'].toString() + ']';
    const elementI = document.createElement('i');
    elementI.setAttribute('class', elementIClass);
    elementA.appendChild(elementI);
    dependencies[i].appendChild(elementA);
  }

  setupFilterForm();
  $('#filter-todo').prop('checked', false);

  // initialize filter for modules results
  const modulesResultFilter = $('#modules_result');
  modulesResultFilter.chosen({ width: '100%' });
  modulesResultFilter.change(function (event) {
    // update query params
    const params = parseQueryParams();
    params.modules_results = modulesResultFilter.val();
  });

  modulesResultFilter.chosen({ width: '100%' });

  // find specified results
  const results = {};
  const states = {};
  const modules_results = [];

  const formatFilter = function (filter) {
    return filter.replace(/_/g, ' ');
  };
  const filterLabels = parseFilterArguments(function (key, val) {
    if (key === 'result') {
      results[val] = true;
      return formatFilter(val);
    } else if (key === 'state') {
      states[val] = true;
      return formatFilter(val);
    } else if (key === 'todo') {
      $('#filter-todo').prop('checked', val !== '0');
      return 'TODO';
    } else if (key === 'arch') {
      $('#filter-arch').prop('value', val);
      return val;
    } else if (key === 'machine') {
      $('#filter-machine').prop('value', val);
      return val;
    } else if (key === 'modules') {
      $('#modules').prop('value', val);
      return val;
    } else if (key === 'modules_result') {
      modules_results.push(val);
      modulesResultFilter.val(modules_results).trigger('chosen:updated').trigger('change');
      return formatFilter(val);
    }
  });

  // set enabled/disabled state of checkboxes (according to current filter)
  if (filterLabels.length > 0) {
    $('#filter-results input').each(function (index, element) {
      element.checked = results[element.id.substr(7)];
    });
    $('#filter-states input').each(function (index, element) {
      element.checked = states[element.id.substr(7)];
    });
  }

  const parentChild = document.getElementsByClassName('parents_children');
  for (let i = 0; i < parentChild.length; i++) {
    parentChild[i].addEventListener('mouseover', highlightDeps);
    parentChild[i].addEventListener('mouseout', unhighlightDeps);
  }
}

function highlightDeps () {
  const parentData = JSON.parse(this.dataset.parentsDeps);
  const childData = JSON.parse(this.dataset.childrenDeps);
  addClassToDependencyJob(parentData, 'highlight_parent');
  addClassToDependencyJob(childData, 'highlight_child');
}

function unhighlightDeps () {
  const parentData = JSON.parse(this.dataset.parentsDeps);
  const childData = JSON.parse(this.dataset.childrenDeps);
  addClassToDependencyJob(parentData, '');
  addClassToDependencyJob(childData, '');
}

function addClassToDependencyJob (array, className) {
  for (let i = 0; i < array.length; i++) {
    const ele = document.getElementsByName('jobid_td_' + array[i])[0];
    if (ele === undefined) { continue; }
    ele.parentNode.className = className;
  }
}
