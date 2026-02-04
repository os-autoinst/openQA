function setupFilterForm(options) {
  // make filter form expandable
  $('#filter-panel .card-header').on('click', function () {
    $('#filter-panel .card-body').toggle(200);
    if ($('#filter-panel').hasClass('filter-panel-bottom')) {
      $('html,body').animate({
        scrollTop: $(document).height()
      });
    }
  });

  $('#filter-panel .help_popover').on('click', function (event) {
    event.stopPropagation();
  });

  if (options && options.preventLoadingIndication) {
    return;
  }

  $('#filter-form').on('submit', function (event) {
    if ($('#filter-form').serialize() !== window.location.search.substring(1)) {
      // show progress indication
      $('#filter-form').hide();
      $('#filter-panel .card-body').append(
        '<span id="filter-progress"><i class="fa fa-cog fa-spin fa-2x fa-fw"></i> <span>Applying filter…</span></span>'
      );
    }
  });

  $('#filter-reset-button').on('click', function () {
    const form = $('#filter-form');
    form.find('input[type="text"], input[type="number"]').val('');
    form.find('input[type="checkbox"]').prop('checked', false).prop('indeterminate', false);
    form.find('input[hidden]').remove();
    form.find('select').val([]).trigger('chosen:updated');
    $('#filter-panel .card-header span').text('no filter present, click to toggle filter form');
  });

  const updateMasterCheckbox = function (container) {
    const master = container.find('.filter-bulk-master');
    if (!master.length) return;
    const checkboxes = container.find('input[type="checkbox"]:not(.filter-bulk-master)');
    const checkedCount = checkboxes.filter(':checked').length;

    if (checkedCount === 0) {
      master.prop('checked', false);
      master.prop('indeterminate', false);
    } else if (checkedCount === checkboxes.length) {
      master.prop('checked', true);
      master.prop('indeterminate', false);
    } else {
      master.prop('checked', false);
      master.prop('indeterminate', true);
    }
  };

  $('#filter-results, #filter-states').on('click', '.filter-bulk-master', function () {
    const container = $(this).closest('.mb-3');
    const isChecked = $(this).prop('checked');
    container.find('input[type="checkbox"]:not(.filter-bulk-master)').prop('checked', isChecked);
  });

  $('#filter-results, #filter-states').on('change', 'input[type="checkbox"]:not(.filter-bulk-master)', function () {
    updateMasterCheckbox($(this).closest('.mb-3'));
  });

  $('#filter-results, #filter-states').on('click', '.filter-bulk-invert', function (e) {
    e.preventDefault();
    const container = $(this).closest('.mb-3');
    container.find('input[type="checkbox"]:not(.filter-bulk-master)').each(function () {
      $(this).prop('checked', !$(this).prop('checked'));
    });
    updateMasterCheckbox(container);
  });

  $('#filter-results, #filter-states').each(function () {
    updateMasterCheckbox($(this));
  });
}

function parseFilterArguments(paramHandler) {
  var varPairs = window.location.search.substring(1).split('&');
  var filterLabels = [];
  var hiddenInputs = [];
  for (var j = 0; j < varPairs.length; ++j) {
    var pair = varPairs[j].split('=');
    if (pair.length > 1) {
      var key = decodeURIComponent(pair[0].replace(/\+/g, '%20'));
      var val = decodeURIComponent(pair[1].replace(/\+/g, '%20'));
      if (val.length < 1) {
        continue;
      }
      var filterLabel = paramHandler(key, val);
      if (filterLabel) {
        filterLabels.push(filterLabel);
      } else {
        var input = $('<input/>');
        input.attr('value', val);
        input.attr('name', key);
        input.attr('hidden', true);
        hiddenInputs.push(input);
      }
    }
  }
  for (var i = 0; i < hiddenInputs.length; i++) {
    $('#filter-form').append(hiddenInputs[i]);
  }
  if (filterLabels.length > 0) {
    $('#filter-panel .card-header')
      .find('span')
      .text('current: ' + filterLabels.join(', '));
  }
  return filterLabels;
}
