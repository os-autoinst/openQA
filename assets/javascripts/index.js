window.onbeforeunload = function () {
  window.unloading = true;
};

function setupIndexPage() {
  setupFilterForm({preventLoadingIndication: true});

  // set default values of filter form
  const filterForm = document.getElementById('filter-form');
  const filterFullScreenCheckBox = document.getElementById('filter-fullscreen');
  const showTagsCheckBox = document.getElementById('filter-show-tags');
  const onlyTaggedCheckBox = document.getElementById('filter-only-tagged');
  const defaultExpanedCheckBox = document.getElementById('filter-default-expanded');
  if (filterFullScreenCheckBox) filterFullScreenCheckBox.checked = false;
  if (showTagsCheckBox) showTagsCheckBox.checked = false;
  if (onlyTaggedCheckBox) {
    onlyTaggedCheckBox.checked = false;
    onlyTaggedCheckBox.addEventListener('change', function () {
      const checked = onlyTaggedCheckBox.checked;
      if (checked) {
        showTagsCheckBox.checked = true;
      }
      showTagsCheckBox.disabled = checked;
    });
  }
  if (defaultExpanedCheckBox) defaultExpanedCheckBox.checked = false;

  // apply query parameters to filter form
  var handleFilterParams = function (key, val) {
    if (key === 'show_tags') {
      showTagsCheckBox.checked = val !== '0';
      return 'show tags';
    } else if (key === 'only_tagged') {
      onlyTaggedCheckBox.checked = val !== '0';
      onlyTaggedCheckBox.dispatchEvent(new Event('change'));
      return 'only tagged';
    } else if (key === 'group') {
      const el = document.getElementById('filter-group');
      if (el) el.value = val;
      return "group '" + val + "'";
    } else if (key === 'limit_builds') {
      const el = document.getElementById('filter-limit-builds');
      if (el) el.value = val;
      return val + ' builds per group';
    } else if (key === 'time_limit_days') {
      const el = document.getElementById('filter-time-limit-days');
      if (el) el.value = val;
      return val + ' days old or newer';
    } else if (key === 'fullscreen') {
      filterFullScreenCheckBox.checked = val !== '0';
      return 'fullscreen';
    } else if (key === 'interval') {
      window.autoreload = val !== 0 ? val : undefined;
      const el = document.getElementById('filter-autorefresh-interval');
      if (el) el.value = val;
      return 'auto refresh';
    } else if (key === 'default_expanded') {
      defaultExpanedCheckBox.checked = val !== '0';
      return 'expanded';
    }
  };
  parseFilterArguments(handleFilterParams);

  loadBuildResults();

  // prevent page reload when submitting filter form (when we load build results via AJAX anyways)
  if (filterForm) {
    filterForm.addEventListener('submit', function (event) {
      if (!window.updatingBuildResults) {
        const queryParams = new URLSearchParams(new FormData(filterForm)).toString();
        loadBuildResults(queryParams);
        history.replaceState({}, document.title, window.location.pathname + '?' + queryParams);
        parseFilterArguments(handleFilterParams);
      }
      toggleFullscreenMode(document.getElementById('filter-fullscreen').checked);
      autoRefreshRestart();
      event.preventDefault();
    });
  }

  toggleFullscreenMode(filterFullScreenCheckBox && filterFullScreenCheckBox.checked);
  autoRefreshRestart();
}

function loadBuildResults(queryParams) {
  const buildResultsElement = document.getElementById('build-results');
  const loadingElement = document.getElementById('build-results-loading');
  const filterForm = document.getElementById('filter-form');
  const filterFormApplyButton = document.getElementById('filter-apply-button');

  if (!window.autoreload) {
    if (loadingElement) loadingElement.style.display = 'block';
    if (buildResultsElement) buildResultsElement.innerHTML = '';
  }
  if (filterFormApplyButton) filterFormApplyButton.disabled = true;
  window.updatingBuildResults = true;

  var showBuildResults = function (buildResults) {
    if (loadingElement) loadingElement.style.display = 'none';
    if (buildResultsElement) buildResultsElement.innerHTML = buildResults;
    document.querySelectorAll('.timeago').forEach(el => {
      if (window.timeago && typeof window.timeago.format === 'function') {
        const date = el.getAttribute('title') || el.getAttribute('datetime');
        if (date) {
          el.textContent = window.timeago.format(date);
        }
      }
    });
    alignBuildLabels();
    if (filterFormApplyButton) filterFormApplyButton.disabled = false;
    window.updatingBuildResults = false;
  };

  // query build results via AJAX using parameters from filter form
  if (!buildResultsElement) return;
  var url = new URL(buildResultsElement.dataset.buildResultsUrl, window.location.href);
  url.search = queryParams ? queryParams : window.location.search.substr(1);
  fetch(url)
    .then(response => {
      if (!response.ok) throw `Server returned ${response.status}: ${response.statusText}`;
      return response.text();
    })
    .then(responsetext => {
      showBuildResults(responsetext);
      window.buildResultStatus = 'success';
    })
    .catch(error => {
      if (window.unloading) {
        return;
      }
      const message = error ? htmlEscape(error) : 'Unable to fetch build results.';
      showBuildResults(
        '<div class="alert alert-danger" role="alert">' +
          message +
          '<a href="javascript:loadBuildResults();" style="float: right;">Try again</a></div>'
      );
    });
}

function autoRefreshRestart() {
  if (window.autoreloadIntervalId) clearInterval(window.autoreloadIntervalId);

  if (window.autoreload > 0) window.autoreloadIntervalId = setInterval(loadBuildResults, window.autoreload * 1000);
}
