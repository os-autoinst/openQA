function setupFilterForm (options) {
  // make filter form expandable
  $('#filter-panel .card-header').on('click', function () {
    $('#filter-panel .card-body').toggle(200)
    if ($('#filter-panel').hasClass('filter-panel-bottom')) {
      $('html,body').animate({
        scrollTop: $(document).height()
      })
    }
  })

  $('#filter-panel .help_popover').on('click', function (event) {
    event.stopPropagation()
  })

  if (options && options.preventLoadingIndication) {
    return
  }

  $('#filter-form').on('submit', function (event) {
    if ($('#filter-form').serialize() !== window.location.search.substring(1)) {
      // show progress indication
      $('#filter-form').hide()
      $('#filter-panel .card-body').append('<span id="filter-progress"><i class="fa fa-cog fa-spin fa-2x fa-fw"></i> <span>Applying filter…</span></span>')
    }
  })
}

function parseFilterArguments (paramHandler) {
  const varPairs = window.location.search.substring(1).split('&')
  const filterLabels = []
  for (let j = 0; j < varPairs.length; ++j) {
    const pair = varPairs[j].split('=')
    if (pair.length > 1) {
      const key = decodeURIComponent(pair[0].replace(/\+/g, '%20'))
      const val = decodeURIComponent(pair[1].replace(/\+/g, '%20'))
      if (val.length < 1) {
        continue
      }
      const filterLabel = paramHandler(key, val)
      if (filterLabel) {
        filterLabels.push(filterLabel)
      } else {
        const input = $('<input/>')
        input.attr('value', val)
        input.attr('name', key)
        input.attr('hidden', true)
        $('#filter-form').append(input)
      }
    }
  }
  if (filterLabels.length > 0) {
    $('#filter-panel .card-header').find('span').text('current: ' + filterLabels.join(', '))
  }
  return filterLabels
}
