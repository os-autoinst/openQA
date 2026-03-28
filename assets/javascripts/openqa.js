function setCookie(cname, cvalue, exdays) {
  const d = new Date();
  d.setTime(d.getTime() + exdays * 24 * 60 * 60 * 1000);
  const expires = 'expires=' + d.toGMTString();
  document.cookie = cname + '=' + cvalue + '; ' + expires;
}

function getCookie(cname) {
  const name = cname + '=';
  const ca = document.cookie.split(';');
  for (let i = 0; i < ca.length; i++) {
    const c = ca[i].trim();
    if (c.indexOf(name) == 0) return c.substring(name.length, c.length);
  }
  return false;
}

function setupForAll() {
  updateTimeago();
  document.querySelectorAll('[data-bs-toggle="popover"]').forEach(e => new bootstrap.Popover(e, {html: true}));
  document.querySelectorAll('[data-bs-toggle="tooltip"]').forEach(e => new bootstrap.Tooltip(e, {html: true}));
  $.ajaxSetup({
    headers: {'X-CSRF-TOKEN': $('meta[name="csrf-token"]').attr('content')}
  });
}

function getCSRFToken() {
  return document.querySelector('meta[name="csrf-token"]').content;
}

function fetchWithCSRF(resource, options) {
  options ??= {};
  options.headers ??= {};
  options.headers['X-CSRF-TOKEN'] ??= getCSRFToken();
  return window.fetch(resource, options);
}

function makeFlashElement(text) {
  return typeof text === 'string' ? '<span>' + text + '</span>' : text;
}

function addFlash(status, text, container, method = 'append') {
  // add flash messages by default on top of the page
  if (!container) {
    container = $('#flash-messages');
  }

  const div = $('<div class="alert alert-primary alert-dismissible fade show" role="alert"></div>');
  div.append(makeFlashElement(text));
  div.append('<button type="button" class="btn-close" data-bs-dismiss="alert" aria-label="Close"></button>');
  div.addClass('alert-' + status);
  container[method](div);
  return div;
}

function addUniqueFlash(status, id, text, container, method = 'append') {
  // add hash to store present flash messages
  if (!window.uniqueFlashMessages) {
    window.uniqueFlashMessages = {};
  }
  // update existing flash message
  const existingFlashMessage = window.uniqueFlashMessages[id];
  if (existingFlashMessage) {
    existingFlashMessage.find('span').first().replaceWith(makeFlashElement(text));
    return;
  }

  const msgElement = addFlash(status, text, container, method);
  window.uniqueFlashMessages[id] = msgElement;
  msgElement.on('closed.bs.alert', function () {
    delete window.uniqueFlashMessages[id];
  });
}

function toggleChildGroups(link) {
  const buildRow = $(link).parents('.build-row');
  buildRow.toggleClass('children-collapsed');
  buildRow.toggleClass('children-expanded');
  return false;
}

function parseQueryParams() {
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

function updateQueryParams(params) {
  if (!history.replaceState) {
    return; // skip if not supported
  }
  const search = [];
  const hash = document.location.hash;
  $.each(params, function (key, values) {
    $.each(values, function (index, value) {
      if (value === undefined) {
        search.push(encodeURIComponent(key));
      } else {
        search.push(encodeURIComponent(key) + '=' + encodeURIComponent(value));
      }
    });
  });
  history.replaceState({}, document.title, `?${search.join('&')}${hash}`);
}

function renderDataSize(sizeInByte) {
  let unitFactor = 1073741824; // one GiB
  let sizeWithUnit = 0;
  $.each([' GiB', ' MiB', ' KiB', ' byte'], function (index, unit) {
    if (!unitFactor || sizeInByte >= unitFactor) {
      sizeWithUnit = Math.round((sizeInByte / unitFactor) * 100) / 100 + unit;
      return false;
    }
    unitFactor >>= 10;
  });
  return sizeWithUnit;
}

function alignBuildLabels() {
  const max = Math.max(...Array.from(document.getElementsByClassName('build-label')).map(e => e.offsetWidth));
  const style = document.createElement('style');
  document.head.appendChild(style);
  style.sheet.insertRule(`@media (min-width: 1000px) { .build-label { width: ${max}px; } }`);
}

// reloads the page - this wrapper exists to be able to disable the reload during tests
function reloadPage() {
  location.reload();
}

function makeUrlPort(servicePortDelta) {
  // read port from the location of the current page
  let port = Number.parseInt(window.location.port);
  if (Number.isNaN(port)) {
    // don't put a port in the URL if there's no explicit port
    port = '';
  } else {
    if (port !== 80 || port !== 443) port += servicePortDelta;
    port = ':' + port;
  }
  return port;
}

function makeUrlAbsolute(url, servicePortDelta) {
  const location = window.location;
  const port = makeUrlPort(servicePortDelta);
  return location.protocol + '//' + location.hostname + port + (url.indexOf('/') !== 0 ? '/' : '') + url;
}

// returns an absolute "ws://" URL for the specified URL which might be relative
function makeWsUrlAbsolute(url, servicePortDelta) {
  // don't adjust URLs which are already absolute
  if (url.indexOf('ws:') === 0) {
    return url;
  }

  const location = window.location;
  const port = makeUrlPort(servicePortDelta);
  return (
    (location.protocol == 'https:' ? 'wss://' : 'ws:/') +
    location.hostname +
    port +
    (url.indexOf('/') !== 0 ? '/' : '') +
    url
  );
}

function renderList(items) {
  const ul = document.createElement('ul');
  items.forEach(function (item) {
    const li = document.createElement('li');
    li.innerHTML = item;
    li.style.whiteSpace = 'pre-wrap';
    ul.appendChild(li);
  });
  return ul;
}

function showJobRestartResults(responseJSON, newJobUrl, retryFunction, targetElement) {
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

function addParam(path, key, value) {
  const paramsStart = path.indexOf('?');
  let params;
  if (paramsStart === -1) {
    params = new URLSearchParams();
    path = path + '?';
  } else {
    params = new URLSearchParams(path.substr(paramsStart + 1));
    path = path.substr(0, paramsStart + 1);
  }
  params.set(key, value);
  return path + params.toString();
}

function forceJobRestartViaRestartLink(restartLink) {
  restartLink.href = addParam(restartLink.href, 'force', '1');
  restartLink.click();
}

function restartJob(ajaxUrl, jobIds, comment) {
  let singleJobId;
  if (!Array.isArray(jobIds)) {
    singleJobId = jobIds;
    jobIds = [jobIds];
  }
  const showError = function (reason) {
    let errorMessage = '<strong>Unable to restart job';
    if (reason) {
      errorMessage += ':</strong> ' + reason;
    } else {
      errorMessage += '.</strong>';
    }
    addFlash('danger', errorMessage);
  };
  const body = new FormData();
  if (comment !== undefined) {
    body.append('comment', comment);
  }
  return fetchWithCSRF(ajaxUrl, {method: 'POST', body: body})
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
      let newJobUrl;
      try {
        if (singleJobId) {
          newJobUrl = json.test_url[0][singleJobId];
        } else {
          const testUrlData = json?.test_url;
          if (Array.isArray(testUrlData)) {
            newJobUrl = testUrlData.map(item => Object.values(item)[0]);
          }
        }
      } catch {
        // Intentionally ignore all errors
      }
      if (
        showJobRestartResults(
          json,
          newJobUrl,
          restartJob.bind(undefined, addParam(ajaxUrl, 'force', '1'), jobIds, comment)
        )
      ) {
        return;
      }
      if (newJobUrl) {
        if (Array.isArray(newJobUrl)) {
          addFlash(
            'info',
            'The jobs have been restarted. <a href="javascript: location.reload()">Reload</a> the page to show changes.'
          );
        } else {
          window.location.replace(newJobUrl);
        }
      } else {
        throw 'URL for new job not available';
      }
    })
    .catch(error => {
      showError(error);
    });
}

function htmlEscape(str) {
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

function renderSearchResults(query, url) {
  const spinner = document.getElementById('progress-indication');
  spinner.style.display = 'block';
  const request = new XMLHttpRequest();
  request.open('GET', urlWithBase('/api/v1/experimental/search?q=' + encodeURIComponent(query)));
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
    heading.appendChild(document.createTextNode(': ' + json.data.total_count + ' matches found'));
    const results = document.createElement('div');
    results.id = 'results';
    results.className = 'list-group';
    const types = {code: 'Test modules', modules: 'Job modules', templates: 'Job Templates'};

    Object.keys(types).forEach(function (searchtype) {
      const searchresults = json.data.results[searchtype];
      if (searchresults.length > 0) {
        const item = document.createElement('div');
        item.className = 'list-group-item';
        const header = document.createElement('h3');
        item.appendChild(header);
        header.id = searchtype;
        const bold = document.createElement('strong');
        const textnode = document.createTextNode(types[searchtype] + ': ' + searchresults.length);
        bold.appendChild(textnode);
        header.appendChild(bold);
        results.append(item);
      }
      searchresults.forEach(function (value, index) {
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

function testStateHTML(job) {
  let className = 'status fa-solid fa-circle';
  let title;
  if (job.state === 'running' || job.state === 'scheduled') {
    if (job.state === 'scheduled' && job.blocked_by_id) {
      className += ' state_blocked';
      title = 'blocked';
    } else {
      className += ' state_' + job.state;
      title = job.state;
    }
  } else if (job.state === 'done') {
    className += ' result_' + job.result;
    title = 'Done: ' + job.result;
  } else if (job.state === 'cancelled') {
    className = 'status fa-solid fa-xmark';
    title = 'cancelled (' + job.result + ')';
  }
  return [className, title];
}

function renderTestState(item, job) {
  item.href = urlWithBase('/tests/' + job.id);
  while (item.firstChild) {
    item.firstChild.remove();
  }
  const icon = document.createElement('i');
  const stateHTML = testStateHTML(job);
  icon.className = stateHTML[0];
  icon.title = stateHTML[1];
  item.appendChild(icon);
  item.appendChild(document.createTextNode(' ' + job.name + ' '));
  if (job.has_parents) {
    const icon = document.createElement('i');
    icon.className = job.parents_ok ? 'fa-solid fa-link' : 'fa-solid fa-link-slash';
    icon.title = job.parents_ok ? 'dependency passed' : 'dependency failed';
    item.appendChild(icon);
  }
}

function updateTestState(job, name, timeElem, reason) {
  renderTestState(name, job);
  if (job.t_finished) {
    timeElem.textContent = timeago.format(job.t_finished);
  }
  if (job.reason) {
    reason.textContent = job.reason;
  }
  // continue polling for job state updates until the job state is done
  if (job.state !== 'done') {
    setTimeout(updateTestState, 5000);
  }
}

function renderJobStatus(item, id) {
  const request = new XMLHttpRequest();
  request.open('GET', urlWithBase('/api/v1/jobs/' + id));
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
    const timeElem = document.createElement('abbr');
    timeElem.className = 'timeago';
    header.appendChild(timeElem);
    item.appendChild(header);
    const details = document.createElement('pre');
    details.className = 'details mb-1';
    const reason = document.createTextNode('');
    details.appendChild(reason);
    item.appendChild(details);
    updateTestState(json.job, name, timeElem, reason);
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

function renderActivityView(ajaxUrl) {
  const spinner = document.getElementById('progress-indication');
  spinner.style.display = 'block';
  const request = new XMLHttpRequest();
  const query = new URLSearchParams();
  query.append('search[value]', 'event:job_');
  query.append('order[0][column]', '1'); // t_created
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
      let id;
      try {
        id = JSON.parse(value.event_data || 'null')?.id;
      } catch (e) {
        return;
      }
      if (!id || uniqueJobs.has(id)) {
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

function renderComments(row) {
  const commentData = row.comment_data;
  let html = '';
  commentData.bugs.forEach(function (bug) {
    html += ` <span id="bug-${row.id}"><a href="${htmlEscape(bug.url)}">`;
    html += `<i class="test-label ${htmlEscape(bug.css_class)}" title="${htmlEscape(bug.title)}"></i>`;
    html += '</a></span>';
  });
  const label = commentData.label;
  if (label) {
    const labelUrl = commentData.label_url;
    html += labelUrl ? ` <a href="${htmlEscape(labelUrl)}">` : ' ';
    html += `<span id="test-label-${row.id}">`;
    html += `<i class="test-label label_${htmlEscape(label)} fa-solid fa-bookmark" title="Label: ${htmlEscape(label)}"></i>`;
    html += labelUrl ? '</span></a>' : '</span>';
  } else if (commentData.comments) {
    html += ` <span id="comment-${row.id}">${commentData.comment_icon}</span>`;
  }
  return html;
}

function renderRestarts(row) {
  let html = '';
  if (row.restarts > 0) {
    const s = row.restarts > 1 ? 's' : '';
    html += ` <span class="restarts" title="Restarted ${row.restarts} time${s}"><i class="fa fa-undo"></i> ${row.restarts}</span>`;
  }
  if (row.clone) {
    html += ` <a href="${urlWithBase('/tests/' + row.clone)}">(restarted)</a>`;
  }
  return html;
}

function renderHttpUrlAsLink(value, oneUrlPerLine = false) {
  if (!value) {
    return document.createTextNode('');
  }
  const fragment = document.createDocumentFragment();
  if (Array.isArray(value)) {
    value.forEach((item, index) => {
      fragment.appendChild(renderHttpUrlAsLink(item));
      if (index < value.length - 1) {
        fragment.appendChild(document.createTextNode(', ')); // seperator between items
      }
    });
    return fragment;
  }
  if (typeof value !== 'string') {
    value = String(value);
  }
  const urlRegex = /https?:\/\/[^\s,]*/g;
  if (oneUrlPerLine) {
    // Regex to match an array of space-separated URLs (to print one per line)
    const arrayOfUrlsRegex = /^(https?:\/\/[^\s,]*)(\s+https?:\/\/[^\s,]*)+\s*$/g;
    oneUrlPerLine = arrayOfUrlsRegex.exec(value) !== null;
  }
  let lastIndex = 0;
  let match;
  while ((match = urlRegex.exec(value)) !== null) {
    if (match.index > lastIndex) {
      fragment.appendChild(document.createTextNode(value.substring(lastIndex, match.index)));
    }
    const a = document.createElement('a');
    a.href = a.textContent = match[0];
    if (oneUrlPerLine) {
      a.style.display = 'block';
    }
    fragment.appendChild(a);
    lastIndex = urlRegex.lastIndex;
  }
  if (lastIndex < value.length) {
    fragment.appendChild(document.createTextNode(value.substring(lastIndex)));
  }
  return fragment.hasChildNodes() ? fragment : document.createTextNode(value);
}

function getXhrError(jqXHR, textStatus, errorThrown) {
  return jqXHR.responseJSON?.error || jqXHR.responseText || errorThrown || textStatus;
}

function updateTimeago() {
  if (typeof timeago !== 'undefined') {
    document.querySelectorAll('.timeago').forEach(e => {
      const val = e.getAttribute('datetime') || e.getAttribute('title') || e.textContent;
      if (!val || val === 'never' || val === 'not yet') return;
      const date = new Date(val);
      if (isNaN(date.getTime()) && !/^\d+$/.test(val)) return;
      if (!e.getAttribute('datetime')) {
        e.setAttribute('datetime', val);
      }
      timeago.render(e);
    });
  }
}

if (typeof window !== 'undefined' && window.jQuery) {
  (function ($) {
    // jQuery 4.0.0 removed several deprecated APIs. These shims maintain compatibility
    // with 3rd-party plugins (chosen) that still rely on these methods.
    // See: https://github.com/jquery/jquery/issues/4884
    //
    // NOTE: timeago has been replaced with timeago.js (vanilla JS, no jQuery dependency).

    // $.active: Removed in jQuery 4. Required by Selenium wait_for_ajax in t/lib/OpenQA/SeleniumTest.pm.
    // Note: Only tracks jQuery $.ajax calls, not fetch(). SeleniumTest.pm checks runningFetchRequests separately.
    if ($.active === undefined) {
      $.active = 0;
      const originalAjax = $.ajax;
      $.ajax = function (url, options) {
        $.active++;
        const jqXHR = originalAjax.apply(this, arguments);
        jqXHR.always(() => {
          $.active = Math.max(0, $.active - 1);
        });
        return jqXHR;
      };
    }

    // $.trim: Removed in jQuery 4. Used by chosen-js/chosen.jquery.js
    if ($.trim === undefined) {
      $.trim = function (str) {
        return String(str).trim();
      };
    }

    // $.isFunction: Removed in jQuery 4. Required by some 3rd-party plugins.
    if ($.isFunction === undefined) {
      $.isFunction = function (obj) {
        return typeof obj === 'function';
      };
    }

    // $.isArray: Removed in jQuery 4. Used by chosen-js/chosen.jquery.js
    if ($.isArray === undefined) {
      $.isArray = Array.isArray;
    }

    // $.isPlainObject: Removed in jQuery 4. Used by chosen-js/chosen.jquery.js
    if ($.isPlainObject === undefined) {
      $.isPlainObject = function (obj) {
        return obj !== null && typeof obj === 'object' && Object.getPrototypeOf(obj) === Object.prototype;
      };
    }

    // $.isEmptyObject: Removed in jQuery 4. Used by chosen-js/chosen.jquery.js
    if ($.isEmptyObject === undefined) {
      $.isEmptyObject = function (obj) {
        return Object.keys(obj).length === 0;
      };
    }

    // $.inArray: Behavior changed in jQuery 4 (now delegates to Array.prototype.indexOf).
    // Used by chosen-js/chosen.jquery.js. Shim for compatibility.
    if ($.inArray === undefined) {
      $.inArray = function (elem, arr, i) {
        return arr ? Array.prototype.indexOf.call(arr, elem, i) : -1;
      };
    }

    // $.fn.timeago: Maintain compatibility with templates using the old jQuery plugin API.
    if ($.fn.timeago === undefined) {
      $.fn.timeago = function () {
        if (typeof timeago !== 'undefined') {
          this.each(function () {
            const val = this.getAttribute('datetime') || this.getAttribute('title') || this.textContent;
            if (!val || val === 'never' || val === 'not yet') return;
            const date = new Date(val);
            if (isNaN(date.getTime()) && !/^\d+$/.test(val)) return;
            if (!this.getAttribute('datetime')) {
              this.setAttribute('datetime', val);
            }
            timeago.render(this);
          });
        }
        return this;
      };
    }

    // Bootstrap 5 jQuery integration might fail with jQuery 4. Add shims if needed.
    if (typeof bootstrap !== 'undefined') {
      if ($.fn.popover === undefined && bootstrap.Popover) {
        $.fn.popover = function (options) {
          return this.each(function () {
            new bootstrap.Popover(this, options);
          });
        };
      }
      if ($.fn.tooltip === undefined && bootstrap.Tooltip) {
        $.fn.tooltip = function (options) {
          return this.each(function () {
            new bootstrap.Tooltip(this, options);
          });
        };
      }
    }
  })(window.jQuery);

  $(document).ready(function () {
    updateTimeago();
    setTimeout(function () {
      const $dropdownToggle = $('.dropdown-menu a.dropdown-toggle');
      if ($dropdownToggle.length) {
        $dropdownToggle.off('click');
        $dropdownToggle.on('click', function (e) {
          const $el = $(this);
          const $parent = $(this).offsetParent('.dropdown-menu');
          if (!$(this).next().hasClass('show')) {
            $(this).parents('.dropdown-menu').first().find('.show').removeClass('show');
          }
          const $subMenu = $(this).next('.dropdown-menu');
          $subMenu.toggleClass('show');
          $(this).parent('li').toggleClass('show');

          if (!$parent.parent().hasClass('navbar-nav')) {
            $el.next().css({top: $el[0].offsetTop + 'px', left: $parent.outerWidth() - 4 + 'px'});
          }

          return false;
        });
      }

      const $dropdown = $('.nav-item.dropdown');
      $dropdown.off('hidden.bs.dropdown');
      $dropdown.on('hidden.bs.dropdown', function (e) {
        $(this).find('.dropdown-menu .show').removeClass('show');
      });
    }, 0);
  });
}
