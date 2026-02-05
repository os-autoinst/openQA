// jshint multistr: true
// jshint esversion: 6

const testStatus = {
  state: null,
  result: null,
  modlist_initialized: 0,
  jobid: null,
  running: null,
  workerid: null,
  status_url: null,
  img_reload_time: 0
};

const tabConfiguration = {
  details: {
    descriptiveName: 'test modules',
    conditionForShowingNavItem: function () {
      return testStatus.state === 'running' || testStatus.state === 'uploading' || testStatus.state === 'done';
    },
    renderContents: renderTestModules
  },
  external: {
    descriptiveName: 'external test results',
    conditionForShowingNavItem: function () {
      return undefined; // shown if the details contain text results
    },
    renderContents: renderExternalTab
  },
  live: {
    descriptiveName: 'live view controls',
    conditionForShowingNavItem: function () {
      return testStatus.state === 'running' || testStatus.state === 'uploading';
    },
    onShow: function () {
      if (this.hasContents) {
        resumeLiveView();
      }
    },
    onHide: function () {
      if (this.hasContents) {
        pauseLiveView();
      }
    },
    onRemove: function () {
      // ensure live view and developer mode are disabled (no-op if already disabled)
      pauseLiveView();
      disableDeveloperMode();
    },
    renderContents: renderLiveTab
  },
  downloads: {
    descriptiveName: 'logs and assets',
    conditionForShowingNavItem: function () {
      return testStatus.state === 'done';
    }
  },
  settings: {
    renderContents: renderSettingsTab
  },
  dependencies: {
    renderContents: renderDependencyTab
  },
  investigation: {
    descriptiveName: 'investigation info',
    conditionForShowingNavItem: function () {
      return testStatus.state === 'done' && (testStatus.result === 'failed' || testStatus.result === 'incomplete');
    },
    renderContents: renderInvestigationTab
  },
  comments: {
    renderContents: renderCommentsTab
  },
  next_previous: {}
};

const DISPLAY_LOG_LIMIT = 5;
const DISPLAY_LINE_LIMIT = 10;

function checkPreviewVisible(stepPreviewContainer, preview) {
  if (!stepPreviewContainer || !preview) return;
  // scroll the element to the top if the preview is not in view
  const containerOffsetTop = stepPreviewContainer.getBoundingClientRect().top + window.scrollY;
  if (containerOffsetTop + preview.offsetHeight > window.scrollY + window.innerHeight) {
    window.scrollTo({
      top: containerOffsetTop - 3,
      behavior: 'auto'
    });
  }

  const rrow = document.getElementById('result-row');
  if (!rrow) return;
  const extraMargin = 40;
  const endOfPreview = containerOffsetTop + preview.offsetHeight + extraMargin;
  const endOfRow = rrow.offsetHeight + (rrow.getBoundingClientRect().top + window.scrollY);
  if (endOfPreview > endOfRow) {
    // only enlarge the margin - otherwise the page scrolls back
    rrow.style.marginBottom = endOfPreview - endOfRow + extraMargin + 'px';
  }
}

function previewSuccess(stepPreviewContainer, data, force) {
  if (!stepPreviewContainer) return;
  // skip if preview has been dismissed
  if (!stepPreviewContainer.classList.contains('current_preview')) {
    return;
  }

  // find the outher and inner preview container
  const pin = document.getElementById('preview_container_in');
  const pout = document.getElementById('preview_container_out');
  if (!pin || !pout) {
    console.error('showing preview/needle diff: Preview container not found');
    return;
  }

  // insert and initialize preview data
  pin.innerHTML = data;
  stepPreviewContainer.parentNode.insertBefore(pout, stepPreviewContainer.nextSibling);
  if (!(pin.querySelector('pre') || pin.querySelector('audio'))) {
    const stepView = pin.querySelector('#step_view');
    const imageSource = stepView ? stepView.dataset.image : null;
    if (!imageSource) {
      console.error('showing preview/needle diff: No image source found');
      return;
    }
    setDiffScreenshot(imageSource);
  }
  const resultElement = document.querySelector('.result');
  const componentElement = document.querySelector('.component');
  pin.style.left =
    -(
      (resultElement ? resultElement.offsetWidth : 0) +
      (componentElement ? componentElement.offsetWidth : 0) +
      2 * 16
    ) + 'px';
  const tdWidth = stepPreviewContainer.closest('td').offsetWidth;
  pout.style.width = tdWidth + 'px';
  pout.style.display = 'none';

  const complete = function () {
    checkPreviewVisible(stepPreviewContainer, pin);
  };

  pout.style.display = 'block';
  complete();

  pin.querySelectorAll('[data-bs-toggle="popover"]').forEach(el => new bootstrap.Popover(el, {html: true}));
  // make persistent dropdowns persistent by preventing click-event propagation
  pin.querySelectorAll('.dropdown-persistent').forEach(el => {
    el.addEventListener('click', function (event) {
      event.stopPropagation();
    });
  });
  // ensure keydown event happening when button has focus is propagated to the right handler
  pin.querySelectorAll('.candidates-selection .dropdown-toggle').forEach(el => {
    el.addEventListener('keydown', function (event) {
      event.stopPropagation();
      handleKeyDownOnTestDetails(event);
    });
  });
  // handle click on the diff selection
  pin.querySelectorAll('.trigger-diff').forEach(el => {
    el.addEventListener('click', function (event) {
      const tr = this.closest('tr');
      if (tr) setNeedle(tr, this.dataset.diff);
      event.stopPropagation();
    });
  });
  // prevent hiding drop down when showing needle info popover
  pin.querySelectorAll('.show-needle-info').forEach(el => {
    el.addEventListener('click', function (event) {
      event.stopPropagation();
    });
  });
  // hide needle info popover when hiding drop down
  var needleDiffDropdown = document.getElementById('needlediff_dropdown');
  if (needleDiffDropdown) {
    needleDiffDropdown.addEventListener('hide.bs.dropdown', function (event) {
      document.querySelectorAll('#needlediff_selector [data-bs-toggle="popover"]').forEach(el => {
        var popover = bootstrap.Popover.getInstance(el);
        if (popover) popover.hide();
      });
    });
  }
}

function toggleTextPreview(textResultDomElement) {
  if (!textResultDomElement) return;
  const textResultElement = textResultDomElement.parentElement;
  if (!textResultElement) return;
  if (textResultElement.classList.contains('current_preview')) {
    // skip if current selection has selected text
    const selection = window.getSelection();
    if (!selection.isCollapsed && textResultDomElement.contains(selection.anchorNode)) {
      return;
    }
    // hide current selection (selected element has been clicked again)
    setCurrentPreview(undefined);
  } else {
    // show new selection, ensure current selection is hidden
    setCurrentPreview(textResultElement);
  }
}

function hidePreviewContainer() {
  const previewContainer = document.getElementById('preview_container_out');
  if (previewContainer) {
    previewContainer.style.display = 'none';
  }
}

function setCurrentPreview(stepPreviewContainer, force) {
  // just hide current preview
  if (!(stepPreviewContainer && !stepPreviewContainer.classList.contains('current_preview')) && !force) {
    document.querySelectorAll('.current_preview').forEach(el => el.classList.remove('current_preview'));
    hidePreviewContainer();
    setPageHashAccordingToCurrentTab('', true);
    return;
  }

  // unselect previous preview
  document.querySelectorAll('.current_preview').forEach(el => el.classList.remove('current_preview'));

  // show preview for results with text data
  const textResultElement = stepPreviewContainer.querySelector('span.text-result');
  if (textResultElement) {
    stepPreviewContainer.classList.add('current_preview');
    hidePreviewContainer();
    setPageHashAccordingToCurrentTab(textResultElement.dataset.href, true);

    // ensure element is in viewport
    const aOffset = stepPreviewContainer.getBoundingClientRect().top + window.scrollY;
    if (aOffset < window.scrollY || aOffset + stepPreviewContainer.offsetHeight > window.scrollY + window.innerHeight) {
      window.scrollTo({
        top: aOffset,
        behavior: 'auto'
      });
    }
    return;
  }

  // show preview for other/regular results
  const link = stepPreviewContainer.querySelector('a');
  if (!link) {
    return;
  }
  if (link.dataset.text) {
    stepPreviewContainer.classList.add('current_preview');
    setPageHashAccordingToCurrentTab(link.getAttribute('href'), true);
    const text = unescape(link.dataset.text);
    previewSuccess(stepPreviewContainer, text, force);
    return;
  }
  if (!link.dataset.url) {
    return;
  }
  stepPreviewContainer.classList.add('current_preview');
  setPageHashAccordingToCurrentTab(link.getAttribute('href'), true);
  fetch(link.dataset.url, {
    method: 'GET',
    headers: {
      'X-Requested-With': 'XMLHttpRequest'
    }
  })
    .then(response => {
      if (!response.ok) throw `Server returned ${response.status}: ${response.statusText}`;
      return response.text();
    })
    .then(data => {
      previewSuccess(stepPreviewContainer, data, force);
    })
    .catch(error => {
      console.warn('Failed to load data from: ' + link.dataset.url, error);
    });
}

function selectPreview(which) {
  const currentPreview = document.querySelector('.current_preview');
  if (!currentPreview) return;
  let linkContainer = which === 'next' ? currentPreview.nextElementSibling : currentPreview.previousElementSibling;
  // skip possibly existing elements between the preview links (eg. the preview container might be between)
  while (linkContainer && !linkContainer.classList.contains('links_a')) {
    linkContainer = which === 'next' ? linkContainer.nextElementSibling : linkContainer.previousElementSibling;
  }
  // select next/prev detail in current step
  if (linkContainer) {
    setCurrentPreview(linkContainer);
    return;
  }
  // select first/last detail in next/prev module
  const row = currentPreview.closest('tr');
  for (;;) {
    if (!row) break;
    row = which === 'next' ? row.nextElementSibling : row.previousElementSibling;
    if (!row) {
      return;
    }
    var links = row.querySelectorAll('.links_a');
    if (links.length) {
      setCurrentPreview(which === 'next' ? links[0] : links[links.length - 1]);
      return;
    }
  }
}

function nextPreview() {
  selectPreview('next');
}

function prevPreview() {
  selectPreview('prev');
}

function prevNeedle() {
  // select previous in current tag
  const currentSelection = document.querySelector('#needlediff_selector tbody tr.selected');
  if (!currentSelection) return;
  let newSelection = currentSelection.previousElementSibling;
  if (!newSelection) {
    // select last in previous tag
    var currentLi = currentSelection.closest('li');
    if (currentLi) {
      var prevLi = currentLi.previousElementSibling;
      while (prevLi) {
        var trs = prevLi.querySelectorAll('tbody tr');
        if (trs.length) {
          newSelection = trs[trs.length - 1];
          break;
        }
        prevLi = prevLi.previousElementSibling;
      }
    }
  }
  if (newSelection) {
    setNeedle(newSelection);
  }
}

function nextNeedle() {
  const currentSelection = document.querySelector('#needlediff_selector tbody tr.selected');
  let newSelection;
  if (!currentSelection) {
    // select first needle in first tag
    newSelection = document.querySelector('#needlediff_selector tbody tr');
  } else {
    // select next in current tag
    newSelection = currentSelection.nextElementSibling;
    if (!newSelection) {
      // select first of next tag
      var currentLi = currentSelection.closest('li');
      if (currentLi) {
        var nextLi = currentLi.nextElementSibling;
        while (nextLi) {
          var trs = nextLi.querySelectorAll('tbody tr');
          if (trs.length) {
            newSelection = trs[0];
            break;
          }
          nextLi = nextLi.nextElementSibling;
        }
      }
    }
  }
  if (newSelection) {
    setNeedle(newSelection);
  }
}

function handleKeyDownOnTestDetails(e) {
  const focusedElement = document.activeElement;
  const ftn = focusedElement ? focusedElement.tagName : '';
  if (ftn === 'INPUT' || ftn === 'TEXTAREA') {
    return;
  }
  if (e.metaKey || e.ctrlKey || e.altKey) {
    return;
  }

  switch (e.key) {
    case 'ArrowLeft':
      if (!e.shiftKey) {
        prevPreview();
        e.preventDefault();
      }
      break;
    case 'ArrowRight':
      if (!e.shiftKey) {
        nextPreview();
        e.preventDefault();
      }
      break;
    case 'Escape':
      if (!e.shiftKey) {
        setCurrentPreview(null);
        e.preventDefault();
      }
      break;
    case 'ArrowUp':
      if (e.shiftKey) {
        prevNeedle();
        e.preventDefault();
      }
      break;
    case 'ArrowDown':
      if (e.shiftKey) {
        nextNeedle();
        e.preventDefault();
      }
      break;
  }
}

function setPageHashAccordingToCurrentTab(tabNameOrHash, replace) {
  // don't mess with #step hashes within details tab
  const currentHash = window.location.hash;
  if (tabNameOrHash === 'details' && (currentHash.startsWith('#step/') || currentHash.startsWith('#line-'))) {
    return;
  }

  const newHash =
    tabNameOrHash === window.defaultTab ? '#' : tabNameOrHash.search('#') === 0 ? tabNameOrHash : '#' + tabNameOrHash;
  if (newHash === currentHash || (newHash === '#' && !currentHash)) {
    return;
  }
  if (replace && history.replaceState) {
    history.replaceState(null, null, newHash);
  } else if (!replace && history.pushState) {
    history.pushState(null, null, newHash);
  } else {
    window.location.hash = newHash;
  }
}

function setupTabHandling() {
  // invoke handlers when a tab gets shown or hidden
  document.querySelectorAll('#result_tabs a[data-bs-toggle="tab"]').forEach(el => {
    el.addEventListener('shown.bs.tab', function (e) {
      if (e.target) {
        const tabName = tabNameForNavElement(e.target);
        activateTab(tabName);
        setPageHashAccordingToCurrentTab(tabName);
      }
      if (e.relatedTarget) {
        deactivateTab(tabNameForNavElement(e.relatedTarget));
      }
    });
  });
  // show relevant nav elements from the start
  showRelevantTabNavElements();
  // change tab when the hash changes and process initial hash
  window.onhashchange = activateTabAccordingToHashChange;
  activateTabAccordingToHashChange();
}

function tabNameForNavElement(navElement) {
  const hash = navElement.hash;
  if (typeof hash === 'string') {
    return hash.substr(1);
  }
}

function configureTabNavElement(tabName, displayStyle) {
  const navElement = document.getElementById('nav-item-for-' + tabName);
  if (!navElement) {
    return false;
  }
  navElement.style.display = displayStyle;
  return navElement;
}

function showTabNavElement(tabName) {
  return configureTabNavElement(tabName, 'list-item');
}

function showRelevantTabNavElements() {
  for (const [tabName, tabConfig] of Object.entries(tabConfiguration)) {
    const conditionForShowingNavItem = tabConfig.conditionForShowingNavItem;
    const shouldDisplayTab = !conditionForShowingNavItem || conditionForShowingNavItem.call();
    // don't mess with tabs handled elsewhere
    if (shouldDisplayTab === undefined) {
      continue;
    }
    const displayStyle = shouldDisplayTab ? 'list-item' : 'none';
    // skip if the tab is not present on the page (e.g. the dependencies tab might not be present at all)
    if (!configureTabNavElement(tabName, displayStyle)) {
      continue;
    }
    // use the tab to be shown as default if there's no default already
    if (shouldDisplayTab) {
      window.defaultTab = window.defaultTab || tabName;
      continue;
    }
    // deactivate and remove the tab if now shown anymore
    if (tabConfig.isActive) {
      deactivateTab(tabName);
    }
    const removeHandler = tabConfig.onRemove;
    if (tabConfig.onRemove) {
      removeHandler.call(tabConfig);
    }
    if (tabConfig.panelElement) {
      tabConfig.panelElement.innerHTML = '';
    }
    tabConfig.initialized = false;
  }
}

function activateTabAccordingToHashChange() {
  // consider hash; otherwise show default tab
  let hash = window.location.hash;
  if (!hash || hash === '#') {
    if (!window.defaultTab) {
      return;
    }
    hash = '#' + window.defaultTab;
  }

  // check for tabs, steps or comments matching the hash
  let link = document.querySelector(`[href='${hash}'], [data-href='${hash}']`);
  let tabName = hash.substr(1);
  const isStep = hash.startsWith('#step/');
  if (hash.startsWith('#line-') || isStep) {
    if (isStep && link) {
      setCurrentPreviewFromStepLinkIfPossible(link);
      // note: It is not a problem if the details haven't been loaded so far. Once the details become available the hash
      //       is checked again and the exact step preview will be shown.
    }
    link = document.querySelector("[href='#details']");
    tabName = 'details';
  } else if (hash.startsWith('#comment-')) {
    link = document.querySelector("[href='#comments']");
    tabName = 'comments';
  } else if (!link || link.getAttribute('role') !== 'tab' || link.classList.contains('active')) {
    setCurrentPreview(null);
    return;
  }

  // show the tab only if supposed to be shown for the current job state; otherwise fall back to the default tab
  const tabConfig = tabConfiguration[tabName];
  if (tabConfig && (!tabConfig.conditionForShowingNavItem || tabConfig.conditionForShowingNavItem())) {
    var tab = bootstrap.Tab.getOrCreateInstance(link);
    tab.show();
  } else {
    window.location.hash = '#';
  }
}

function renderTabContent(tabConfig, response) {
  const customRenderer = tabConfig.renderContents;
  if (customRenderer) {
    return Promise.resolve(customRenderer.call(tabConfig, response));
  }
  tabConfig.panelElement.innerHTML = response;
  return Promise.resolve();
}

function loadTabPanelElement(tabName, tabConfig) {
  const tabPanelElement = document.getElementById(tabName);
  if (!tabPanelElement) {
    return false;
  }
  const ajaxUrl = tabPanelElement.dataset.src;
  if (!ajaxUrl) {
    return false;
  }
  tabConfig.panelElement = tabPanelElement; // for easier access in custom renderers
  if (tabConfig._abortController) {
    tabConfig._abortController.abort();
  }
  tabConfig._abortController = new AbortController();
  fetch(ajaxUrl, {method: 'GET', signal: tabConfig._abortController.signal})
    .then(response => {
      if (!response.ok) throw `Server returned ${response.status}: ${response.statusText}`;
      if (response.headers.get('Content-Type').includes('application/json')) return response.json();
      return response.text();
    })
    .then(response => {
      if (!tabConfig.isActive) {
        tabConfig._deferredResponse = response;
        return;
      }
      tabConfig._deferredResponse = undefined;
      return renderTabContent(tabConfig, response);
    })
    .catch(error => {
      if (error.name === 'AbortError') return;
      console.error(`Error loading tab '${tabName}':`, error);
      const customRenderer = tabConfig.renderError;
      if (customRenderer) {
        return customRenderer.call(tabConfig, error);
      }
      tabPanelElement.innerHTML = '';
      tabPanelElement.appendChild(
        document.createTextNode(`Unable to load ${tabConfig.descriptiveName || tabName}: ${error}`)
      );
    });
  tabPanelElement.innerHTML =
    '<p style="text-align: center;"><i class="fa-solid fa-spinner fa-spin fa-lg"></i> Loading ' +
    (tabConfig.descriptiveName || tabName) +
    '…</p>';
  return tabPanelElement;
}

function activateTab(tabName) {
  if (!tabName) {
    return false;
  }
  const tabConfig = tabConfiguration[tabName];
  if (!tabConfig) {
    // skip tabs which don't exists
    // note: Some tabs might not be rendered at all, e.g. the dependencies tab is only rendered if there are dependencies.
    return false;
  }
  tabConfig.isActive = true;
  if (!tabConfig.initialized) {
    return (tabConfig.initialized = loadTabPanelElement(tabName, tabConfig));
  }
  if (tabConfig._deferredResponse) {
    const response = tabConfig._deferredResponse;
    renderTabContent(tabConfig, response)
      .then(() => {
        tabConfig._deferredResponse = undefined;
      })
      .catch(error => {
        console.error(`Error rendering deferred content for tab '${tabName}':`, error);
        tabConfig._deferredResponse = undefined;
      });
  }
  const showHandler = tabConfig.onShow;
  if (showHandler) {
    return showHandler.call(tabConfig);
  }
}

function deactivateTab(tabName) {
  if (!tabName) {
    return false;
  }
  const tabConfig = tabConfiguration[tabName];
  if (!tabConfig) {
    return false;
  }
  tabConfig.isActive = false;
  const hideHandler = tabConfig.onHide;
  if (hideHandler) {
    return hideHandler.call(tabConfig);
  }
}

function setInfoPanelClassName(jobState, jobResult) {
  const panelClassByResult = {passed: 'border-success', softfailed: 'border-warning'};
  document.getElementById('info_box').className =
    'card ' + (jobState !== 'done' ? 'border-info' : panelClassByResult[jobResult] || 'border-danger');
}

function setupResult(jobid, state, result, status_url) {
  // make test state and result available to all JavaScript functions which need it
  testStatus.state = state;
  testStatus.result = result;
  testStatus.jobid = jobid;

  setupTabHandling();
  loadEmbeddedLogFiles();
  if (state !== 'done') {
    setupRunning(jobid, status_url);
    return;
  }
  setInfoPanelClassName(state, result);
}

function delay(callback, ms) {
  let timer;
  return function () {
    clearTimeout(timer);
    timer = setTimeout(callback.bind(this, ...arguments), ms || 0);
  };
}

function filterLogLines(input, viaSearchBox = true) {
  if (input === undefined) {
    return;
  }
  const string = input.value;
  if (string === input.dataset.lastString) {
    // abort if the value does not change which can happen because there are multiple event handlers calling this function
    return;
  }
  const match = string.match(/^\/(.*)\/([i]*)$/);
  const regex = match ? new RegExp(match[1], match[2]) : undefined;
  input.dataset.lastString = string;
  displaySearchInfo('Searching…');
  document.querySelectorAll('.embedded-logfile').forEach(logFileElement => {
    const content = logFileElement.content;
    if (content === undefined) {
      return;
    }
    const lines = Array.from(content);
    let lineNumber = 0;
    let matchingLines = 0;
    if (string.length > 0) {
      for (const line of lines) {
        const lineAsText = ansiToText(line);
        if (regex ? lineAsText.match(regex) : lineAsText.includes(string)) {
          ++matchingLines;
        } else {
          lines[lineNumber] = undefined;
        }
        ++lineNumber;
      }
      displaySearchInfo(`Showing ${matchingLines} / ${lineNumber} lines`);
    } else {
      displaySearchInfo('');
    }
    showLogLines(logFileElement, lines, viaSearchBox);
  });
  const params = parseQueryParams();
  string.length > 0 ? (params.filter = [string]) : delete params.filter;
  updateQueryParams(params);
}

function filterEmbeddedLogFiles() {
  const searchBox = document.getElementById('filter-log-file');
  if (searchBox) {
    const filterParam = parseQueryParams().filter?.[0];
    if (filterParam !== undefined) {
      searchBox.value = filterParam;
    }
  }
  loadEmbeddedLogFiles(filterLogLines.bind(null, searchBox, false));
}

function showLogLines(logFileElement, lines, viaSearchBox = false) {
  const tableElement = document.createElement('table');
  const currentHash = document.location.hash;
  let lineNumber = 0;
  let currentLineElement = undefined;
  logFileElement.innerHTML = '';
  for (const line of lines) {
    ++lineNumber;
    if (line === undefined) {
      continue;
    }
    const lineElement = document.createElement('tr');
    const lineNumberElement = document.createElement('td');
    const lineNumberLinkElement = document.createElement('a');
    const lineContentElement = document.createElement('td');
    const hash = '#' + (lineElement.id = 'line-' + lineNumber);
    lineNumberLinkElement.href = hash;
    lineNumberLinkElement.onclick = () => {
      if (currentLineElement !== undefined) {
        currentLineElement.classList.remove('line-current');
      }
      lineContentElement.classList.add('line-current');
      currentLineElement = lineContentElement;
    };
    lineNumberLinkElement.append(lineNumber);
    lineNumberElement.className = 'line-number';
    lineContentElement.className = 'line-content';
    if (hash === currentHash) {
      lineNumberLinkElement.onclick();
    }
    lineContentElement.innerHTML = ansiToHtml(line);
    lineNumberElement.appendChild(lineNumberLinkElement);
    lineElement.append(lineNumberElement, lineContentElement);
    tableElement.appendChild(lineElement);
  }
  logFileElement.appendChild(tableElement);

  // trigger the current hash again or delete it if no longer valid
  if (currentLineElement && !viaSearchBox) {
    currentLineElement.scrollIntoView();
  } else if (currentHash.startsWith('line-') && !currentLineElement) {
    document.location.hash = '';
  }

  // setup event handler to update the current line when the hash changes
  if (window.hasHandlerForUpdatingCurrentLine) {
    return;
  }
  addEventListener('hashchange', event => {
    const hash = document.location.hash;
    if (hash.startsWith('#line-')) {
      const lineNumberLinkElement = document.querySelector(hash + ' .line-number a');
      if (lineNumberLinkElement) {
        lineNumberLinkElement.onclick();
      }
    }
  });
  window.hasHandlerForUpdatingCurrentLine = true;
}

function loadEmbeddedLogFiles(filter) {
  document.querySelectorAll('.embedded-logfile').forEach(logFileElement => {
    if (logFileElement.dataset.contentsLoaded) {
      return;
    }
    fetch(logFileElement.dataset.src)
      .then(response => {
        if (!response.ok) throw `Server returned ${response.status}: ${response.statusText}`;
        return response.text();
      })
      .then(response => {
        const lines = (logFileElement.content = response.split(/\r?\n/));
        filter ? filter() : showLogLines(logFileElement, lines, false);
        logFileElement.dataset.contentsLoaded = true;
      })
      .catch(error => {
        console.error(error);
        logFileElement.appendChild(document.createTextNode(`Unable to load logfile: ${error}`));
      });
  });
}

window.onload = function () {
  const searchBox = document.getElementById('filter-log-file');
  if (!searchBox) {
    return;
  }
  const filter = filterLogLines.bind(null, searchBox, true);
  searchBox.addEventListener('keyup', delay(filter), 1000);
  searchBox.addEventListener('change', filter, false);
  searchBox.addEventListener('search', filter, false);
};

function displaySearchInfo(text) {
  document.getElementById('filter-info').innerHTML = text;
}

function setCurrentPreviewFromStepLinkIfPossible(stepLink) {
  if (tabConfiguration.details.hasContents && !stepLink.parent().is('.current_preview')) {
    setCurrentPreview(stepLink.parent());
  }
}

function githashToLink(value, repo) {
  if (!value.match(/^([0-9a-f]+) /)) {
    return null;
  }
  const logItems = value.split(/(?=^[0-9a-f])/gm);
  const commits = [];
  for (let i = 0; i < logItems.length; i++) {
    const item = logItems[i];
    const match = item.match(/^([0-9a-f]+) (.*)/);
    if (match === null) {
      return null;
    }
    const sha = match[1];
    const msg = match[2];
    commits.push({link: sha.link(repo + sha), msg: msg, stat: item.match(/^ .*/gm)});
  }
  return commits;
}

function setupTestDetailsFilter(tabConfig) {
  if (tabConfig._hasFilterHandlers) return;

  // load the embedded logfiles (autoinst-log.txt); assume that in this case no test modules are available and skip further processing
  if (this.panelElement.getElementsByClassName('embedded-logfile').length > 0) {
    loadEmbeddedLogFiles();
    return;
  }

  setupLazyLoadingFailedSteps();

  // enable the external tab if there are text results
  // note: It would be more efficient to query "regular details" and external results in one go because both
  //       are just a different representation of the same data.
  if (document.getElementsByClassName('external-result-container').length) {
    showTabNavElement('external');
  }

  // display the preview for the current step according to the hash
  const hash = window.location.hash;
  if (hash.search('#step/') === 0) {
    setCurrentPreviewFromStepLinkIfPossible(
      document.querySelector("[href='" + hash + "'], [data-href='" + hash + "']")
    );
  }

  // setup event handlers for the window
  if (!this.hasWindowEventHandlers) {
    // setup keyboard navigation through test details
    window.addEventListener('keydown', handleKeyDownOnTestDetails);

    // ensure the size of the preview container is adjusted when the window size changes
    window.addEventListener('resize', function () {
      const currentPreview = document.querySelector('.current_preview');
      if (currentPreview) {
        setCurrentPreview(currentPreview, true);
      }
    });
    this.hasWindowEventHandlers = true;
  }

  // setup result filter, define function to apply filter changes
  const detailsFilter = document.getElementById('details-filter');
  const detailsNameFilter = document.getElementById('details-name-filter');
  const detailsFailedOnlyFilter = document.getElementById('details-only-failed-filter');
  const resultsTable = document.getElementById('results');
  let anyFilterEnabled = false;
  let nameFilter = '';
  let nameFilterEnabled = false;
  let failedOnlyFilterEnabled = false;
  const applyFilterChanges = function (event) {
    if (!resultsTable) return;
    // determine enabled filter
    anyFilterEnabled = detailsFilter && !detailsFilter.classList.contains('hidden');
    if (anyFilterEnabled) {
      nameFilter = detailsNameFilter ? detailsNameFilter.value : '';
      nameFilterEnabled = nameFilter.length !== 0;
      failedOnlyFilterEnabled = detailsFailedOnlyFilter ? detailsFailedOnlyFilter.checked : false;
      anyFilterEnabled = nameFilterEnabled || failedOnlyFilterEnabled;
    }

    // show everything if no filter present
    if (!anyFilterEnabled) {
      resultsTable.querySelectorAll('tbody tr').forEach(tr => (tr.style.display = ''));
      return;
    }

    // hide all categories
    resultsTable.querySelectorAll('tbody tr td[colspan="3"]').forEach(td => {
      if (td.parentElement) td.parentElement.style.display = 'none';
    });

    // show/hide table rows considering filter
    resultsTable.querySelectorAll('tbody .result').forEach(td => {
      const trElement = td.parentElement;
      if (!trElement) return;
      const componentTd = trElement.querySelector('td.component');
      const stepMaches =
        (!nameFilterEnabled || (componentTd && componentTd.textContent.indexOf(nameFilter) >= 0)) &&
        (!failedOnlyFilterEnabled ||
          td.classList.contains('resultfailed') ||
          td.classList.contains('resultsoftfailed'));
      trElement.style.display = stepMaches ? '' : 'none';
    });
  };

  if (detailsNameFilter) detailsNameFilter.addEventListener('keyup', applyFilterChanges);
  if (detailsFailedOnlyFilter) detailsFailedOnlyFilter.addEventListener('change', applyFilterChanges);

  // setup filter toggle
  document.querySelectorAll('.details-filter-toggle').forEach(el => {
    el.addEventListener('click', function (event) {
      event.preventDefault();
      if (detailsFilter) {
        detailsFilter.classList.toggle('hidden');
        applyFilterChanges();
      }
    });
  });

  tabConfig._hasFilterHandlers = true;
}

function setupTestDetailsWindowEventHandlers(tabConfig) {
  if (tabConfig._hasWindowEventHandlers) return;
  $(window).keydown(handleKeyDownOnTestDetails);
  $(window).resize(() => {
    if ($('.current_preview').length) {
      setCurrentPreview($('.current_preview'), true);
    }
  });
  tabConfig._hasWindowEventHandlers = true;
}

function renderTestModules(response) {
  this.hasContents = true;
  const tabConfig = this;

  return renderModuleTable(this.panelElement, response, () => tabConfig.isActive)
    .then(completed => {
      if (!completed) return;

      if (tabConfig.panelElement.getElementsByClassName('embedded-logfile').length > 0) {
        loadEmbeddedLogFiles();
        return;
      }

      setupLazyLoadingFailedSteps();

      if (document.getElementsByClassName('external-result-container').length) {
        showTabNavElement('external');
      }

      const hash = window.location.hash;
      if (hash.search('#step/') === 0) {
        setCurrentPreviewFromStepLinkIfPossible($("[href='" + hash + "'], [data-href='" + hash + "']"));
      }

      setupTestDetailsWindowEventHandlers(tabConfig);
      setupTestDetailsFilter(tabConfig);
    })
    .catch(error => {
      console.error('Error rendering test modules:', error);
      tabConfig.panelElement.innerHTML = '';
      tabConfig.panelElement.appendChild(document.createTextNode(`Unable to render test modules: ${error}`));
    });
}

function renderExternalTab(response) {
  this.panelElement.innerHTML = response;

  const tableEl = document.getElementById('external-table');
  // skip if table is not present (meaning no external results available) or if the table has
  // already been initialized
  if (!tableEl || tableEl.dataset.initialized) {
    return;
  }

  // make the table use DataTable
  tableEl.dataset.initialized = 'true';
  const externalTable = new DataTable(tableEl, {
    lengthMenu: [
      [10, 25, 50, 100],
      [10, 25, 50, 100]
    ],
    order: []
  });

  // setup filtering
  const onlyFailedCheckbox = document.getElementById('external-only-failed-filter');
  if (onlyFailedCheckbox) {
    onlyFailedCheckbox.addEventListener('change', function (event) {
      externalTable.draw();
    });
    DataTable.ext.search.push(function (settings, data, dataIndex) {
      // don't apply filter if checkbox not checked
      if (!onlyFailedCheckbox.checked) {
        return true;
      }
      // filter out everything but failures and softfailures
      const rowData = externalTable.row(dataIndex).data();
      if (!rowData) {
        return false;
      }
      const result = rowData[2];
      return result && (result.indexOf('result_fail') > 0 || result.indexOf('result_softfail') > 0);
    });
  }
}

function renderLiveTab(response) {
  this.hasContents = true;
  this.panelElement.innerHTML = response;
  initLivelogAndTerminal();
  if (testStatus.state === 'uploading' || testStatus.state === 'done') {
    disableLivestream();
  } else {
    initLivestream();
  }
  setupDeveloperPanel();
  resumeLiveView();
}

function renderCommentsTab(response) {
  const tabPanelElement = this.panelElement;
  tabPanelElement.innerHTML = response;
  tabPanelElement.querySelectorAll('[data-bs-toggle="popover"]').forEach(el => new bootstrap.Popover(el, {html: true}));
  // Add job status icons to /t123 urls
  const hostname = window.location.host;
  tabPanelElement.querySelectorAll('a').forEach(element => {
    const href = element.getAttribute('href');
    if (!href) {
      return;
    }
    const re = new RegExp('^(?:https?://' + hostname + ')?/(?:tests/|t)([0-9]+)$');
    const found = href.match(re);
    if (!found) {
      return;
    }
    const id = found[1];
    const url = urlWithBase('/api/v1/experimental/jobs/' + id + '/status');
    fetch(url)
      .then(response => {
        if (!response.ok) throw `Server returned ${response.status}: ${response.statusText}`;
        return response.json();
      })
      .then(job => {
        if (job.error) throw job.error;
        const span = document.createElement('span');
        span.className = 'openqa-testref';
        const i = document.createElement('i');
        const stateHTML = testStateHTML(job);
        i.className = stateHTML[0];
        span.title = stateHTML[1];
        span.appendChild(i);
        element.parentNode.replaceChild(span, element);
        span.appendChild(element);
      })
      .catch(error => {
        console.error(error);
      });
  });
}

function renderInvestigationTab(response) {
  if (typeof response !== 'object') {
    tabPanelElement.innerHTML = 'Investigation info returned by server is invalid.';
    return;
  }
  const tabPanelElement = this.panelElement;
  const testgiturl = response.testgiturl;
  const needlegiturl = response.needlegiturl;
  delete response.testgiturl;
  delete response.needlegiturl;
  document.getElementById('investigation').setAttribute('data-testgiturl', testgiturl);
  document.getElementById('investigation').setAttribute('data-needlegiturl', needlegiturl);

  const theadElement = document.createElement('thead');
  const headTrElement = document.createElement('tr');
  const headThElement = document.createElement('th');
  headThElement.appendChild(document.createTextNode('Investigation'));
  headThElement.colSpan = 2;
  headTrElement.appendChild(headThElement);
  theadElement.appendChild(headTrElement);

  const tbodyElement = document.createElement('tbody');
  let alertbox;
  Object.keys(response).forEach(key => {
    const value = response[key];
    let type = 'pre';

    // The value can be an object with attribute "type" to determine the
    // behavior. The accepted types are:
    // - link: adds a link reference using an anchor <a>
    //   additional required attributes:
    //     - link: the url
    //     - text: the text to show instead of the url

    if (typeof value === 'object' && value.type) type = value.type;

    const keyElement = document.createElement('td');
    keyElement.style.verticalAlign = 'top';
    keyElement.appendChild(document.createTextNode(key));

    const valueElement = document.createElement('td');

    let textLinesRest;

    if (type === 'link') {
      const html = document.createElement('a');
      if (key === 'first_bad') {
        alertbox = document.createElement('div');
        alertbox.appendChild(document.createTextNode('Investigate the first bad test directly: '));
        html.href = value.link + '#investigation';
        html.innerHTML = value.text;
        alertbox.appendChild(html);
        alertbox.className = 'alert alert-info';
        html.className = 'alert-link';
        return;
      } else {
        html.href = value.link;
        html.innerHTML = value.text;
        valueElement.appendChild(html);
      }
    } else {
      const preElement = document.createElement('pre');
      let preElementMore = document.createElement('pre');
      let enable_more = false;
      const repoUrl = getInvestigationDataAttr(key);
      if (repoUrl) {
        const gitstats = githashToLink(value, repoUrl);
        // assume string 'No test changes..'
        if (gitstats === null) {
          preElement.appendChild(document.createTextNode(value));
        } else {
          for (let i = 0; i < gitstats.length; i++) {
            const statItem = document.createElement('div');
            const collapseSign = document.createElement('a');
            collapseSign.className = 'collapsed';
            collapseSign.setAttribute('href', '#collapse' + key + i);
            collapseSign.setAttribute('data-bs-toggle', 'collapse');
            collapseSign.setAttribute('aria-expanded', 'false');
            collapseSign.setAttribute('aria-controls', 'collapseEntry');
            collapseSign.innerHTML = '+ ';
            collapseSign.setAttribute('onclick', 'toggleSign(this)');
            const spanElem = document.createElement('span');
            const logDetailsDiv = document.createElement('div');
            logDetailsDiv.id = 'collapse' + key + i;
            logDetailsDiv.className = 'collapse';
            spanElem.innerHTML = gitstats[i].link + ' ' + gitstats[i].msg;
            logDetailsDiv.innerHTML = gitstats[i].stat.join('\n');
            statItem.append(collapseSign, spanElem, logDetailsDiv);

            if (i < DISPLAY_LOG_LIMIT) {
              preElement.appendChild(statItem);
            } else {
              enable_more = true;
              preElementMore.appendChild(statItem);
            }
          }
        }
      } else {
        let textLines = typeof value === 'string' ? value.split('\n') : [value];

        if (textLines.length > DISPLAY_LINE_LIMIT) {
          textLinesRest = textLines.slice(DISPLAY_LINE_LIMIT, textLines.length);
          textLines = textLines.slice(0, DISPLAY_LINE_LIMIT);
        }
        preElement.appendChild(document.createTextNode(textLines.join('\n')));
      }

      valueElement.appendChild(preElement);

      if (textLinesRest) {
        enable_more = true;
        preElementMore = document.createElement('pre');
        preElementMore.appendChild(document.createTextNode(textLinesRest.join('\n')));
      }
      if (enable_more) {
        preElementMore.style = 'display: none';

        const moreLink = document.createElement('a');
        moreLink.style = 'cursor:pointer';
        moreLink.innerHTML = 'Show more';
        moreLink.onclick = function () {
          preElementMore.style = '';
          moreLink.style = 'display:none';
        };

        valueElement.appendChild(moreLink);
        valueElement.appendChild(preElementMore);
      }
    }

    const trElement = document.createElement('tr');
    trElement.appendChild(keyElement);
    trElement.appendChild(valueElement);
    tbodyElement.appendChild(trElement);
  });

  const tableElement = document.createElement('table');
  tableElement.id = 'investigation_status_entry';
  tableElement.className = 'infotbl table table-striped';
  tableElement.appendChild(theadElement);
  tableElement.appendChild(tbodyElement);
  tabPanelElement.innerHTML = '';
  if (alertbox) {
    tabPanelElement.appendChild(alertbox);
  }
  tabPanelElement.appendChild(tableElement);
  tabPanelElement.dataset.initialized = true;
}

function toggleSign(elem) {
  elem.innerHTML = elem.className === 'collapsed' && elem.innerHTML === '+ ' ? '- ' : '+ ';
}

function getInvestigationDataAttr(key) {
  const attrs = {test_log: 'data-testgiturl', needles_log: 'data-needlegiturl'};
  const investigation = document.getElementById('investigation');
  return investigation ? investigation.getAttribute(attrs[key]) : null;
}

function renderSettingsTab(response) {
  const tabPanelElement = this.panelElement;
  tabPanelElement.innerHTML = response;
  Array.from(tabPanelElement.getElementsByClassName('settings-value')).forEach(settingsLink => {
    const url = settingsLink.textContent;
    settingsLink.innerHTML = null;
    settingsLink.appendChild(renderHttpUrlAsLink(url, true));
  });
}

function renderDependencyTab(response) {
  const tabPanelElement = this.panelElement;
  const nodes = response.nodes;
  const edges = response.edges;
  const cluster = response.cluster;
  if (!nodes || !edges || !cluster) {
    tabPanelElement.innerHTML = 'Unable to query dependency info: no nodes/edges received';
    return;
  }
  tabPanelElement.innerHTML =
    '<p>Arrows visualize chained dependencies specified via <code>START_AFTER_TEST</code> \
                                 and <code>START_DIRECTLY_AFTER_TEST</code> (hover over boxes to distinguish). \
                                 Blue boxes visualize parallel dependencies specified via <code>PARALLEL_WITH</code>. \
                                 The current job is highlighted with a bolder border and yellow background.</p> \
                                 <p>The graph shows only the latest jobs. That means jobs which have been cloned will \
                                 never show up.</p><svg id="dependencygraph"></svg>';

  // render the graph only while the tab panel element is visible; otherwise delay the rendering until it becomes visible
  // note: This is required because otherwise the initialization does not seem to work (e.g. in Chromium only the arrows
  //       are rendered and in Firefox nothing at all).
  const renderGraph = renderDependencyGraph.bind(
    this,
    tabPanelElement,
    nodes,
    edges,
    cluster,
    tabPanelElement.dataset.currentJobId
  );
  if (tabPanelElement.classList.contains('active')) {
    renderGraph();
  } else {
    const tabLink = document.querySelector("[href='#dependencies']");
    if (tabLink) {
      tabLink.addEventListener('shown.bs.tab', renderGraph, {once: true});
    }
  }
}

function renderDependencyGraph(container, nodes, edges, cluster, currentNode) {
  // create a new directed graph
  const g = new dagreD3.graphlib.Graph({compound: true}).setGraph({});

  // set left-to-right layout and spacing
  g.setGraph({
    rankdir: 'LR',
    nodesep: 10,
    ranksep: 50,
    marginx: 10,
    marginy: 10
  });

  // insert nodes
  const nodeIDs = {};
  nodes.forEach(node => {
    let testResultId;
    if (node.result !== 'none') {
      testResultId = node.result;
    } else {
      testResultId = node.state;
      if (testResultId === 'scheduled' && node.blocked_by_id) {
        testResultId = 'blocked';
      }
    }
    const testResultName = testResultId.replace(/_/g, ' ');

    g.setNode(node.id, {
      label: function () {
        const table = document.createElement('table');
        table.id = 'nodeTable' + node.id;
        const tr = d3.select(table).append('tr');

        const testNameTd = tr.append('td');
        if (node.id == currentNode) {
          testNameTd.text(node.label);
          tr.node().className = 'current';
        } else {
          const testNameLink = testNameTd.append('a');
          testNameLink.attr('href', urlWithBase('/tests/' + node.id) + '#dependencies');
          testNameLink.text(node.label);
        }

        const testResultTd = tr.append('td');
        testResultTd.text(testResultName);
        testResultTd.node().className = testResultId;

        return table;
      },
      padding: 0,
      name: node.name,
      testResultId: testResultId,
      testResultName: testResultName,
      startAfter: node.chained,
      startDirectlyAfter: node.directly_chained,
      parallelWith: node.parallel
    });
    nodeIDs[node.id] = true;
  });

  // insert edges
  edges
    .sort((a, b) => a.from - b.from || a.to - b.to)
    .forEach(edge => {
      if (nodeIDs[edge.from] && nodeIDs[edge.to]) {
        g.setEdge(edge.from, edge.to, {});
      }
    });

  // insert clusters
  Object.keys(cluster).forEach(clusterId => {
    g.setNode(clusterId, {});
    cluster[clusterId].forEach(child => {
      if (nodeIDs[child]) {
        g.setParent(child, clusterId);
      }
    });
  });

  // create the renderer
  const render = new dagreD3.render();

  // set up an SVG group so that we can translate the final graph.
  const svg = d3.select('svg'),
    svgGroup = svg.append('g');

  // run the renderer (this is what draws the final graph)
  render(svgGroup, g);

  // add tooltips
  svgGroup
    .selectAll('g.node')
    .attr('title', function (v) {
      const node = g.node(v);
      let tooltipText = '<p>' + node.name + '</p>';
      const startAfter = node.startAfter;
      const startDirectlyAfter = node.startDirectlyAfter;
      const parallelWith = node.parallelWith;
      if (startAfter.length || startDirectlyAfter.length || parallelWith.length) {
        tooltipText += '<div style="border-top: 1px solid rgba(100, 100, 100, 30); margin: 5px 0px;"></div>';
        if (startAfter.length) {
          tooltipText += '<p><code>START_AFTER_TEST=' + htmlEscape(startAfter.join(',')) + '</code></p>';
        }
        if (startDirectlyAfter.length) {
          tooltipText +=
            '<p><code>START_DIRECTLY_AFTER_TEST=' + htmlEscape(startDirectlyAfter.join(',')) + '</code></p>';
        }
        if (parallelWith.length) {
          tooltipText += '<p><code>PARALLEL_WITH=' + htmlEscape(parallelWith.join(',')) + '</code></p>';
        }
      }
      return tooltipText;
    })
    .each(function (v) {
      new bootstrap.Tooltip(this, {
        html: true,
        placement: 'right'
      });
    });

  // move the graph a bit to the bottom so lines at the top are not clipped
  svgGroup.attr('transform', 'translate(0, 20)');

  // set width and height of the svg element to the graph's size plus a bit extra spacing
  svg.attr('width', g.graph().width + 40);
  svg.attr('height', g.graph().height + 40);

  // note: centering is achieved by centering the svg element itself like any other html block element
}

function rescheduleProductForJob(link) {
  if (
    window.confirm(
      'Do you really want to partially reschedule the product of this job? This will' +
        ' NOT be limited to the current job group! Click on the help icon for details.'
    )
  ) {
    rescheduleProduct(link.dataset.url);
  }
  return false; // avoid usual link handling
}

module = {};
