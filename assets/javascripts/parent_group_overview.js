function setupParentGroupOverviewAssets(group_id) {
  var cookieProductName = '_product_' + group_id + '_grouped_by';
  var cookieAllProductsName = 'product_all_grouped_by';

  function setCookie(name, value) {
    document.cookie = name + '=' + value;
  }

  function getCookie(name) {
    var value = '; ' + document.cookie;
    var parts = value.split('; ' + name + '=');
    if (parts.length == 2) return parts.pop().split(';').shift();
  }

  function updateGroupedByDefaultLinks() {
    const defaultEl = document.getElementById('grouped_by_default');
    if (defaultEl) {
      defaultEl.style.display = window.location.hash !== getCookie(cookieProductName) ? 'inline-block' : 'none';
    }

    const defaultAllEl = document.getElementById('grouped_by_default_all');
    if (defaultAllEl) {
      defaultAllEl.style.display = window.location.hash !== getCookie(cookieAllProductsName) ? 'inline-block' : 'none';
    }
  }

  function updateView() {
    const groupByGroup = document.getElementById('grouped_by_group');
    const groupByBuild = document.getElementById('grouped_by_build');
    if (window.location.hash === '#grouped_by_build') {
      if (groupByGroup) groupByGroup.style.display = 'none';
      if (groupByBuild) groupByBuild.style.display = 'block';
    } else {
      if (groupByGroup) groupByGroup.style.display = 'block';
      if (groupByBuild) groupByBuild.style.display = 'none';
    }
  }

  function updateGroupedByClasses() {
    const groupTab = document.getElementById('grouped_by_group_tab');
    const buildTab = document.getElementById('grouped_by_build_tab');
    if (!groupTab || !buildTab) return;

    if (window.location.hash === undefined || window.location.hash === '#grouped_by_build') {
      groupTab.classList.remove('active', 'parent_group_overview_grouping_active');
      buildTab.classList.add('active', 'parent_group_overview_grouping_active');
    } else {
      buildTab.classList.remove('active', 'show', 'parent_group_overview_grouping_active');
      groupTab.classList.add('active', 'parent_group_overview_grouping_active');
    }
  }

  const initialize = function () {
    var defaultHash = '#grouped_by_build';
    var hash = window.location.hash;

    if (hash === undefined || hash === '') hash = getCookie(cookieProductName);

    if (hash === undefined || hash === '') hash = getCookie(cookieAllProductsName);

    if (hash === undefined || hash === '') hash = defaultHash;

    window.location.hash = hash;

    updateGroupedByClasses();
    updateGroupedByDefaultLinks();
    updateView();

    document.querySelectorAll('.nav-tabs a').forEach(el => {
      el.addEventListener('click', function (event) {
        var hash = this.getAttribute('href');
        window.location.hash = hash;
        updateGroupedByDefaultLinks();
        updateGroupedByClasses();
        updateView();
        event.preventDefault();
      });
    });

    const defaultEl = document.getElementById('grouped_by_default');
    if (defaultEl) {
      defaultEl.addEventListener('click', function () {
        setCookie(cookieProductName, window.location.hash || defaultHash);
        updateGroupedByDefaultLinks();
      });
    }

    const defaultAllEl = document.getElementById('grouped_by_default_all');
    if (defaultAllEl) {
      defaultAllEl.addEventListener('click', function () {
        setCookie(cookieAllProductsName, window.location.hash || defaultHash);
        updateGroupedByDefaultLinks();
      });
    }
  };

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initialize);
  } else {
    initialize();
  }
}
