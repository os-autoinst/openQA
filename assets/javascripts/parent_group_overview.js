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
    if (window.location.hash !== getCookie(cookieProductName)) $('#grouped_by_default').show();
    else $('#grouped_by_default').hide();

    if (window.location.hash !== getCookie(cookieAllProductsName)) $('#grouped_by_default_all').show();
    else $('#grouped_by_default_all').hide();
  }

  function updateView() {
    if (window.location.hash === '#grouped_by_build') {
      $('#grouped_by_group').hide();
      $('#grouped_by_build').show();
    } else {
      $('#grouped_by_group').show();
      $('#grouped_by_build').hide();
    }
  }

  function updateGroupedByClasses() {
    clearFlash(); // Do not let the notification messages hanging when group is updated
    if (window.location.hash === undefined || window.location.hash === '#grouped_by_build') {
      document
        .getElementById('grouped_by_group_tab')
        .classList.remove('active', 'parent_group_overview_grouping_active');
      document.getElementById('grouped_by_build_tab').classList.add('active', 'parent_group_overview_grouping_active');
    } else {
      document
        .getElementById('grouped_by_build_tab')
        .classList.remove('active', 'show', 'parent_group_overview_grouping_active');
      document.getElementById('grouped_by_group_tab').classList.add('active', 'parent_group_overview_grouping_active');
      hiddenBuilds = document.querySelectorAll('.no-build-data');
      if (hiddenBuilds.length > 0) {
        hiddenBuilds.forEach(elem => {
          console.log(elem.dataset.buildName);
        });
        addFlash(
          'info',
          `Parent group has ${hiddenBuilds.length} more builds with no results in the current build limits.`
        );
      }
    }
  }

  $(document).ready(function () {
    var defaultHash = '#grouped_by_build';
    var hash = window.location.hash;

    if (hash === undefined || hash === '') hash = getCookie(cookieProductName);

    if (hash === undefined || hash === '') hash = getCookie(cookieAllProductsName);

    if (hash === undefined || hash === '') hash = defaultHash;

    window.location.hash = hash;

    updateGroupedByClasses();
    updateGroupedByDefaultLinks();
    updateView();

    $('.nav-tabs a').click(function (event) {
      var hash = $(this).attr('href');
      window.location.hash = hash;
      updateGroupedByDefaultLinks();
      updateGroupedByClasses();
      updateView();
      event.preventDefault();
    });

    $('#grouped_by_default').click(function () {
      setCookie(cookieProductName, window.location.hash || defaultHash);
      updateGroupedByDefaultLinks();
    });

    $('#grouped_by_default_all').click(function () {
      setCookie(cookieAllProductsName, window.location.hash || defaultHash);
      updateGroupedByDefaultLinks();
    });
  });
}
