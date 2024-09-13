function setupIndexPage() {
  setupFilterForm({preventLoadingIndication: true});

  // set default values of filter form
  var filterForm = $('#filter-form');
  var filterFullScreenCheckBox = $('#filter-fullscreen');
  var showTagsCheckBox = $('#filter-show-tags');
  var onlyTaggedCheckBox = $('#filter-only-tagged');
  var defaultExpanedCheckBox = $('#filter-default-expanded');
  filterFullScreenCheckBox.prop('checked', false);
  showTagsCheckBox.prop('checked', false);
  onlyTaggedCheckBox.prop('checked', false);
  onlyTaggedCheckBox.on('change', function () {
    var checked = onlyTaggedCheckBox.prop('checked');
    if (checked) {
      showTagsCheckBox.prop('checked', true);
    }
    showTagsCheckBox.prop('disabled', checked);
  });
  defaultExpanedCheckBox.prop('checked', false);

  // apply query parameters to filter form
  var handleFilterParams = function (key, val) {
    if (key === 'show_tags') {
      showTagsCheckBox.prop('checked', val !== '0');
      return 'show tags';
    } else if (key === 'only_tagged') {
      onlyTaggedCheckBox.prop('checked', val !== '0');
      onlyTaggedCheckBox.trigger('change');
      return 'only tagged';
    } else if (key === 'group') {
      $('#filter-group').prop('value', val);
      return "group '" + val + "'";
    } else if (key === 'limit_builds') {
      $('#filter-limit-builds').prop('value', val);
      return val + ' builds per group';
    } else if (key === 'time_limit_days') {
      $('#filter-time-limit-days').prop('value', val);
      return val + ' days old or newer';
    } else if (key === 'fullscreen') {
      filterFullScreenCheckBox.prop('checked', val !== '0');
      return 'fullscreen';
    } else if (key === 'interval') {
      window.autoreload = val !== 0 ? val : undefined;
      $('#filter-autorefresh-interval').prop('value', val);
      return 'auto refresh';
    } else if (key === 'default_expanded') {
      defaultExpanedCheckBox.prop('checked', val !== '0');
      return 'expanded';
    }
  };
  parseFilterArguments(handleFilterParams);

  loadBuildResults();

  // prevent page reload when submitting filter form (when we load build results via AJAX anyways)
  filterForm.submit(function (event) {
    if (!window.updatingBuildResults) {
      var queryParams = filterForm.serialize();
      loadBuildResults(queryParams);
      history.replaceState({}, document.title, window.location.pathname + '?' + queryParams);
      parseFilterArguments(handleFilterParams);
    }
    toggleFullscreenMode($('#filter-fullscreen').is(':checked'));
    autoRefreshRestart();
    event.preventDefault();
  });

  toggleFullscreenMode(filterFullScreenCheckBox.is(':checked'));
  autoRefreshRestart();
}

function loadBuildResults(queryParams) {
  var buildResultsElement = $('#build-results');
  var loadingElement = $('#build-results-loading');
  var filterForm = $('#filter-form');
  var filterFormApplyButton = $('#filter-apply-button');

  if (!window.autoreload) {
    loadingElement.show();
    buildResultsElement.html('');
  }
  filterFormApplyButton.prop('disabled', true);
  window.updatingBuildResults = true;

  var showBuildResults = function (buildResults) {
    loadingElement.hide();
    buildResultsElement.html(buildResults);
    $('.timeago').timeago();
    alignBuildLabels();
    filterFormApplyButton.prop('disabled', false);
    window.updatingBuildResults = false;
  };

  // query build results via AJAX using parameters from filter form
  var url = new URL(buildResultsElement.data('build-results-url'), window.location.href);
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
