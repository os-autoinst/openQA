function previewSuccess(data) {
  $('#preview_container_in').html(data);
  /* var hotlink = location.hash.replace(/\/tests\/[0-9]+\/modules\//, '');
  window.history.replaceState({}, 'preview', hotlink); */
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

  $('#preview_container_out').insertAfter(td.children('.links_a').eq(preview_offset));
  if ($('#preview_container_in').find('pre').length > 0 || $('#preview_container_in').find('audio').length > 0) {
    $('#preview_container_in').find('pre, div').css('width', $('.links').width());
    $('#preview_container_in').css('left', 0);
    $('#preview_container_in').addClass('nobg');
  }
  else {
    $('#preview_container_in').css('left', -($('.result').width()+$('.component').width()+2*16));
    $('#preview_container_in').removeClass('nobg');
    
    window.differ = new NeedleDiff('needle_diff', 1024, 768);
    setDiffScreenshot(window.differ, $('#preview_container_in #step_view').data('image'));
    setNeedle();
  }
  $('#preview_container_out').css('display', 'block').css('height', $('#preview_container_in').height());
  $('body, html').stop(true, true).animate({scrollTop: a.offset().top-3, queue: false}, 250);
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
    window.location.hash = link.attr('href');
    $.get({ url: link.data('url'), success: previewSuccess}).fail(function() { setCurrentPreview(); alert("foo"); });
  }
  else {
    window.location.hash = '';
    // hide
    $('#preview_container_out').hide();
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
  if (hash) {
    var link = $('[href="' + hash + '"]');
    if (link && link.attr('role') === 'tab') { link.tab('show'); };
    if (hash.search('#step/') == 0) {
      if (link && !link.parent().is('.current_preview')) {
	setCurrentPreview(link.parent());
      } else if (!link) {
	setCurrentPreview();
      }
    }
  } else {
    // reset
    setCurrentPreview();
  }
}

function setupPreview() {

  $('.current_preview').removeClass('current_preview');
  
  $(window).keydown(function(e) {
    var ftn = $(':focus').prop("tagName");
    if (ftn == "INPUT" || ftn == "TEXTAREA") {
      return;
    }
    if (e.shiftKey || e.metaKey || e.ctrlKey || e.altKey) {
      return;
    }
    if (e.which == 37) { // left
      prev();
      e.preventDefault();
    }
    else if (e.which == 39) { // right
      next();
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

  $(window).on('hashchange', checkResultHash);
  checkResultHash();
  
  $(document).on('change', '#needlediff_selector', setNeedle);

}

