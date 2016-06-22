function checkPreviewVisible(a, preview) {
  // scroll the element to the top if the preview is not in view
  if (a.offset().top + preview.height() > $(window).scrollTop() + $(window).height()) {
    $('body, html').animate({
      scrollTop: a.offset().top-3
    }, 250);
  }

  var rrow = $('#result-row');
  var extraMargin = 40;
  var endOfPreview =  a.offset().top + preview.height() + extraMargin;
  var endOfRow = rrow.height() + rrow.offset().top;
  if (endOfPreview > endOfRow) {
    // only enlarge the margin - otherwise the page scrolls back
    rrow.css('margin-bottom', endOfPreview - endOfRow + extraMargin);
  }
}

function previewSuccess(data, force) {
  $('#preview_container_in').html(data);
  var a = $('.current_preview');
  var td = a.parent();

  var a_index = td.children('.links_a').index(a);

  // a width = 64
  var as_per_row = Math.floor(td.width() / 64);
  var full_top_rows = Math.ceil((a_index+1) / as_per_row);
  var preview_offset = (as_per_row * full_top_rows) - 1;
  var as_count = td.children('.links_a').length - 1;
  if (as_count < preview_offset) {
    preview_offset = as_count;
  }

  var pout = $('#preview_container_out');
  // make it visible so jquery gets the props right
  pout.insertAfter(td.children('.links_a').eq(preview_offset));

  var pin = $('#preview_container_in');
  if (!(pin.find('pre').length || pin.find('audio').length)) {
    window.differ = new NeedleDiff('needle_diff', 1024, 768);
    setDiffScreenshot(window.differ, $('#preview_container_in #step_view').data('image'));
    setNeedle();
  }
  pin.css('left', -($('.result').width()+$('.component').width()+2*16));
  var tdWidth = $('.current_preview').parents('td').width();
  pout.width(tdWidth).hide().fadeIn({
    duration: (force?0:150),
    complete: function() {
      checkPreviewVisible(a, pin);
    }
  });
}

function setResultHash(hash) {
  // the details tab is the real page
  if (hash == '#details')
    hash = '#';
  if(history.pushState) {
    history.pushState(null, null, hash);
  } else {
    location.hash = hash;
  }
}

function setCurrentPreview(a, force) {
  if ((a && a.length && !a.is('.current_preview')) || force) {
    // show
    $('.current_preview').removeClass('current_preview');

    var link = a.find('a');
    if (!link || !link.data('url')) {
      return;
    }
    a.addClass('current_preview');
    setResultHash(link.attr('href'));
    $.get({ url: link.data('url'), success: function(data) { previewSuccess(data, force); }}).fail(function() { setCurrentPreview(); });
  }
  else {
    // hide
    $('#preview_container_out').fadeOut(150);
    $('.current_preview').removeClass('current_preview');
  }
}

function nextPreview() {
  var a = $('.current_preview');
  if(a) {
    var table = $('.current_preview').parents('table');
    var a_index = table.find('.links_a').index(a);
    var next_a = a_index + 1;
    var b = table.find('.links_a').eq(next_a);
    if (b.length) {
      setCurrentPreview(b);
    }
  }
}

function prevPreview() {
  var a = $('.current_preview');
  if (a) {
    var table = $('.current_preview').parents('table');
    var a_index = table.find('.links_a').index(a);
    var next_a = a_index - 1;
    if (next_a >= 0) {
      var b = table.find('.links_a').eq(next_a);
      if (b.length) {
        setCurrentPreview(b);
      }
    }
  }
}

function checkResultHash() {
  var hash = window.location.hash;
  if (!hash || hash == '#') {
    hash = '#details';
  }
  var link = $('[href="' + hash + '"]');
  if (link && link.attr('role') === 'tab') {
    if (!link.prop('aria-expanded')) {
      link.tab('show');
    }
  }
  if (hash.search('#step/') == 0) {
    if (link && !link.parent().is('.current_preview')) {
      setCurrentPreview(link.parent());
    } else if (!link) {
      setCurrentPreview();
    }
  } else {
    // reset
    setCurrentPreview();
  }
}

function setupResult(state, jobid) {

  $('.current_preview').removeClass('current_preview');
  
  $(window).keydown(function(e) {
    var ftn = $(':focus').prop("tagName");
    if (ftn == "INPUT" || ftn == "TEXTAREA") {
      return;
    }
    if (e.shiftKey || e.metaKey || e.ctrlKey || e.altKey) {
      return;
    }
    if (e.which == KeyEvent.DOM_VK_LEFT) {
      prevPreview();
      e.preventDefault();
    }
    else if (e.which == KeyEvent.DOM_VK_RIGHT) {
      nextPreview();
      e.preventDefault();
    } else if (e.which == KeyEvent.DOM_VK_ESCAPE) {
      setCurrentPreview();
      e.preventDefault();
    }
  });

  $(window).resize(function() {
    if($('.current_preview')) {
      setCurrentPreview($('.current_preview'), true);
    }
  });

  $('.links_a > a').on('click', function() {
    setCurrentPreview($(this).parent());
    return false;
  });

  // don't overwrite the tab if coming from the URL (ignore '#')
  if (location.hash.length < 2) {
    if (state == 'scheduled') {
      $('#result_tabs a[href="#settings"]').tab('show');
    } else if (state == 'running' || state == 'waiting') {
      $('#result_tabs a[href="#live"]').tab('show');
    }
  }
  if (state == 'running' || state == 'waiting') {
    setupRunning(jobid);
  }
  $(window).on('hashchange', checkResultHash);
  checkResultHash();
  
  $(document).on('change', '#needlediff_selector', setNeedle);
  $('a[data-toggle="tab"]').on('show.bs.tab', function(e) {
    setResultHash($(e.target).attr('href'));
  });
}

