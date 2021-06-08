function setCookie (cname, cvalue, exdays) {
  const d = new Date();
  d.setTime(d.getTime() + (exdays * 24 * 60 * 60 * 1000));
  const expires = 'expires=' + d.toGMTString();
  document.cookie = cname + '=' + cvalue + '; ' + expires;
}

function getCookie (cname) {
  const name = cname + '=';
  const ca = document.cookie.split(';');
  for (let i = 0; i < ca.length; i++) {
    const c = ca[i].trim();
    if (c.indexOf(name) == 0) return c.substring(name.length, c.length);
  }
  return false;
}

function setupForAll () {
  $('[data-toggle="tooltip"]').tooltip({ html: true });
  $('[data-toggle="popover"]').popover({ html: true });
  // workaround for popover with hover on text for firefox
  $('[data-toggle="popover"]').on('click', function (e) {
    e.target.closest('a').focus();
  });

  // $('[data-submenu]').submenupicker();

  $.ajaxSetup({
    headers: { 'X-CSRF-TOKEN': $('meta[name="csrf-token"]').attr('content') }
  });
}

function addFlash (status, text, container) {
  // add flash messages by default on top of the page
  if (!container) {
    container = $('#flash-messages');
  }

  const div = $('<div class="alert alert-primary alert-dismissible fade show" role="alert"></div>');
  if (typeof text === 'string') {
    div.append($('<span>' + text + '</span>'));
  } else {
    div.append(text);
  }
  div.append($('<button type="button" class="close" data-dismiss="alert" aria-label="Close"><span aria-hidden="true">&times;</span></button>'));
  div.addClass('alert-' + status);
  container.append(div);
  return div;
}

function addUniqueFlash (status, id, text, container) {
  // add hash to store present flash messages
  if (!window.uniqueFlashMessages) {
    window.uniqueFlashMessages = {};
  }
  // update existing flash message
  const existingFlashMessage = window.uniqueFlashMessages[id];
  if (existingFlashMessage) {
    existingFlashMessage.find('span').first().text(text);
    return;
  }

  const msgElement = addFlash(status, text, container);
  window.uniqueFlashMessages[id] = msgElement;
  msgElement.on('closed.bs.alert', function () {
    delete window.uniqueFlashMessages[id];
  });
}

function toggleChildGroups (link) {
  const buildRow = $(link).parents('.build-row');
  buildRow.toggleClass('children-collapsed');
  buildRow.toggleClass('children-expanded');
  return false;
}

function parseQueryParams () {
  const params = {};
  for (const [key, value] of new URLSearchParams(document.location.search.substring(1))) {
    if (Array.isArray(params[key])) {
      params[key].push(value);
    } else {
      params[key] = [value];
    }
  }
  return params;
}

function updateQueryParams (params) {
  if (!history.replaceState) {
    return; // skip if not supported
  }
  const search = [];
  $.each(params, function (key, values) {
    $.each(values, function (index, value) {
      if (value === undefined) {
        search.push(encodeURIComponent(key));
      } else {
        search.push(encodeURIComponent(key) + '=' + encodeURIComponent(value));
      }
    });
  });
  history.replaceState({}, document.title, window.location.pathname + '?' + search.join('&'));
}

function renderDataSize (sizeInByte) {
  let unitFactor = 1073741824; // one GiB
  let sizeWithUnit = 0;
  $.each([' GiB', ' MiB', ' KiB', ' byte'], function (index, unit) {
    if (!unitFactor || sizeInByte >= unitFactor) {
      sizeWithUnit = (Math.round(sizeInByte / unitFactor * 100) / 100) + unit;
      return false;
    }
    unitFactor >>= 10;
  });
  return sizeWithUnit;
}

function alignBuildLabels () {
  const values = $.map($('.build-label'), function (el, index) { return parseInt($(el).css('width')); });
  const max = Math.max.apply(null, values);
  $('.build-label').css('min-width', max + 'px');
}

// reloads the page - this wrapper exists to be able to disable the reload during tests
function reloadPage () {
  location.reload();
}

// returns an absolute "ws://" URL for the specified URL which might be relative
function makeWsUrlAbsolute (url, servicePortDelta) {
  // don't adjust URLs which are already absolute
  if (url.indexOf('ws:') === 0) {
    return url;
  }

  // read port from the page's current URL
  const location = window.location;
  let port = Number.parseInt(location.port);
  if (Number.isNaN(port)) {
    // don't put a port in the URL if there's no explicit port
    port = '';
  } else {
    if (port !== 80 || port !== 443) {
      // if not using default ports we assume we're not accessing the web UI via Apache/NGINX
      // reverse proxy
      // -> so if not specified otherwise, we're further assuming a connection to the livehandler
      //    daemon which is supposed to run under the <web UI port> + 2
      port += servicePortDelta || 2;
    }
    port = ':' + port;
  }

  return (location.protocol == 'https:' ? 'wss://' : 'ws:/') +
        location.hostname + port +
        (url.indexOf('/') !== 0 ? '/' : '') +
        url;
}

function renderList (items) {
  const ul = document.createElement('ul');
  items.forEach(function (item) {
    const li = document.createElement('li');
    li.innerHTML = item;
    li.style.whiteSpace = 'pre-wrap';
    ul.appendChild(li);
  });
  return ul;
}

function showJobRestartResults (responseJSON, newJobUrl, retryFunction, targetElement) {
  const hasResponse = typeof responseJSON === 'object';
  const errors = hasResponse ? responseJSON.errors : ['Server returned invalid response'];
  const warnings = hasResponse ? responseJSON.warnings : undefined;
  const hasErrors = Array.isArray(errors) && errors.length > 0;
  const hasWarnings = Array.isArray(warnings) && warnings.length > 0;
  if (!hasErrors && !hasWarnings) {
    return false;
  }
  const container = document.createElement('div');
  if (hasResponse && responseJSON.enforceable && retryFunction) {
    const button = document.createElement('button');
    button.onclick = retryFunction;
    button.className = 'btn btn-danger force-restart';
    button.style.float = 'right';
    button.appendChild(document.createTextNode('Force restart'));
    container.appendChild(button);
  }
  if (hasWarnings) {
    container.appendChild(document.createTextNode('Warnings occurred when restarting jobs:'));
    container.appendChild(renderList(warnings));
  }
  if (hasErrors) {
    container.appendChild(document.createTextNode('Errors occurred when restarting jobs:'));
    container.appendChild(renderList(errors));
  }
  if (newJobUrl !== undefined) {
    const link = document.createElement('a');
    link.href = newJobUrl;
    link.appendChild(document.createTextNode('new job'));
    container.appendChild(document.createTextNode('Go to '));
    container.appendChild(link);
    container.appendChild(document.createTextNode('.'));
  }
  addFlash(hasErrors ? 'danger' : 'warning', container, targetElement);
  return true;
}

function forceJobRestartViaRestartLink (restartLink) {
  if (!restartLink.href.endsWith('?force=1')) {
    restartLink.href += '?force=1';
  }
  restartLink.click();
}

function restartJob (ajaxUrl, jobId) {
  const showError = function (reason) {
    let errorMessage = '<strong>Unable to restart job';
    if (reason) {
      errorMessage += ':</strong> ' + reason;
    } else {
      errorMessage += '.</strong>';
    }
    addFlash('danger', errorMessage);
  };

  return $.ajax({
    type: 'POST',
    url: ajaxUrl,
    success: function (data, res, xhr) {
      const responseJSON = xhr.responseJSON;
      let newJobUrl;
      try {
        newJobUrl = responseJSON.test_url[0][jobId];
      } catch {}
      if (showJobRestartResults(responseJSON, newJobUrl, restartJob.bind(undefined, ajaxUrl + '?force=1', jobId))) {
        return;
      }
      if (newJobUrl) {
        window.location.replace(newJobUrl);
      } else {
        showError('URL for new job not available');
      }
    },
    error: function (xhr, ajaxOptions, thrownError) {
      showError(xhr.responseJSON ? xhr.responseJSON.error : undefined);
    }
  });
}

function htmlEscape (str) {
  if (str === undefined || str === null) {
    return '';
  }
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}

function renderSearchResults (query, url) {
  const spinner = document.getElementById('progress-indication');
  spinner.style.display = 'block';
  const request = new XMLHttpRequest();
  request.open('GET', '/api/v1/experimental/search?q=' + encodeURIComponent(query));
  request.setRequestHeader('Accept', 'application/json');
  request.onload = function () {
    // Make sure we have valid JSON here
    // And check that we have valid data, errors are not valid data
    let json;
    try {
      json = JSON.parse(this.responseText);
      if (!json.data) {
        throw 'Invalid search results';
      }
    } catch (error) {
      request.onerror();
      return;
    }
    spinner.style.display = 'none';
    const heading = document.getElementById('results-heading');
    heading.appendChild(document.createTextNode(': ' + json.data.length + ' matches found'));
    const results = document.createElement('div');
    results.id = 'results';
    results.className = 'list-group';
    json.data.forEach(function (value, index) {
      const item = document.createElement('div');
      item.className = 'list-group-item';
      const header = document.createElement('div');
      header.className = 'd-flex w-100 justify-content-between';
      const title = document.createElement('h5');
      title.className = 'occurrence mb-1';
      title.appendChild(document.createTextNode(value.occurrence));
      header.appendChild(title);
      item.appendChild(header);
      if (value.contents) {
        const contents = document.createElement('pre');
        contents.className = 'contents mb-1';
        contents.appendChild(document.createTextNode(value.contents));
        item.appendChild(contents);
      }
      results.append(item);
    });
    const oldResults = document.getElementById('results');
    oldResults.parentElement.replaceChild(results, oldResults);
  };
  request.onerror = function () {
    spinner.style.display = 'none';
    let msg = this.statusText;
    try {
      const json = JSON.parse(this.responseText);
      if (json && json.error) {
        msg = json.error.split(/\n/)[0];
      } else if (json && json.error_status) {
        msg = json.error_status;
      }
    } catch (error) {
      msg = error;
    }
    addFlash('danger', 'Search resulted in error: ' + msg);
  };
  request.send();
}

function renderTestState (item, job) {
  item.href = '/tests/' + job.id;
  while (item.firstChild) {
    item.firstChild.remove();
  }
  if (job.state === 'done') {
    const icon = document.createElement('i');
    icon.className = 'status fa fa-circle';
    if (job.result == 'none' && (job.state == 'running' || job.state == 'scheduled')) {
      icon.className += ' state_' + job.state;
      icon.title = job.state;
    } else {
      icon.className += ' result_' + job.result;
      icon.title = 'Done: ' + job.result;
    }
    item.appendChild(icon);
  } else if (job.state === 'cancelled') {
    const icon = document.createElement('i');
    icon.className = 'fa fa-times';
    icon.title = 'cancelled';
    item.appendChild(icon);
  }
  item.appendChild(document.createTextNode(' ' + job.name + ' '));
  if (job.has_parents) {
    const icon = document.createElement('i');
    icon.className = job.parents_ok ? 'fa fa-link' : 'fa fa-unlink';
    icon.title = job.parents_ok ? 'dependency passed' : 'dependency failed';
    item.appendChild(icon);
  }
}

function updateTestState (job, name, timeago, reason) {
  renderTestState(name, job);
  if (job.t_finished) {
    timeago.textContent = jQuery.timeago(job.t_finished);
  }
  if (job.reason) {
    reason.textContent = job.reason;
  }
  // continue polling for job state updates until the job state is done
  if (job.state !== 'done') {
    setTimeout(updateTestState, 5000);
  }
}

function renderJobStatus (item, id) {
  const request = new XMLHttpRequest();
  request.open('GET', '/api/v1/jobs/' + id);
  request.setRequestHeader('Accept', 'application/json');
  request.onload = function () {
    // Make sure we have valid JSON here
    // And check that we have valid data, errors are not valid data
    let json;
    try {
      json = JSON.parse(this.responseText);
      if (!json.job) {
        throw 'Invalid job details returned';
      }
    } catch (error) {
      request.onerror();
      return;
    }
    const header = document.createElement('div');
    header.className = 'd-flex w-100 justify-content-between';
    const title = document.createElement('h5');
    title.className = 'event_name mb-1';
    const name = document.createElement('a');
    header.appendChild(name);
    header.appendChild(title);
    const timeago = document.createElement('abbr');
    timeago.className = 'timeago';
    header.appendChild(timeago);
    item.appendChild(header);
    const details = document.createElement('pre');
    details.className = 'details mb-1';
    const reason = document.createTextNode('');
    details.appendChild(reason);
    item.appendChild(details);
    updateTestState(json.job, name, timeago, reason);
  };
  request.onerror = function () {
    let msg = this.statusText;
    try {
      const json = JSON.parse(this.responseText);
      if (json && json.error) {
        msg = json.error.split(/\n/)[0];
      } else if (json && json.error_status) {
        msg = json.error_status;
      }
    } catch (error) {
      msg = error;
    }
    item.appendChild(document.createTextNode(msg));
  };
  request.send();
}

function renderActivityView (ajaxUrl, currentUser) {
  const spinner = document.getElementById('progress-indication');
  spinner.style.display = 'block';
  const request = new XMLHttpRequest();
  const query = new URLSearchParams();
  query.append('search[value]', 'user:' + encodeURIComponent(currentUser) + ' event:job_');
  query.append('order[0][column]', '0'); // t_created
  query.append('order[0][dir]', 'desc');
  request.open('GET', ajaxUrl + '?' + query.toString());
  request.setRequestHeader('Accept', 'application/json');
  request.onload = function () {
    // Make sure we have valid JSON here
    // And check that we have valid data, errors are not valid data
    let json;
    try {
      json = JSON.parse(this.responseText);
      if (!json.data) {
        throw 'Invalid events returned';
      }
    } catch (error) {
      request.onerror();
      return;
    }
    spinner.style.display = 'none';
    const results = document.createElement('div');
    results.id = 'results';
    results.className = 'list-group';
    const uniqueJobs = new Set();
    json.data.forEach(function (value, index) {
      // The audit log interprets _ as a wildcard so we enforce the prefix here
      if (!/job_/.test(value.event)) {
        return;
      }
      // We want only the latest result of each job
      const id = JSON.parse(value.event_data).id;
      if (uniqueJobs.has(id)) {
        return;
      }
      uniqueJobs.add(id);

      const item = document.createElement('div');
      item.className = 'list-group-item';
      renderJobStatus(item, id);
      results.append(item);
    });
    const oldResults = document.getElementById('results');
    oldResults.parentElement.replaceChild(results, oldResults);
  };
  request.onerror = function () {
    spinner.style.display = 'none';
    let msg = this.statusText;
    try {
      const json = JSON.parse(this.responseText);
      if (json && json.error) {
        msg = json.error.split(/\n/)[0];
      } else if (json && json.error_status) {
        msg = json.error_status;
      }
    } catch (error) {
      msg = error;
    }
    addFlash('danger', 'Search resulted in error: ' + msg);
  };
  request.send();
}
