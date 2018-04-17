function checkPreviewVisible(a, preview) {
  // scroll the element to the top if the preview is not in view
  if (a.offset().top + preview.height() > $(window).scrollTop() + $(window).height()) {
    $("body, html").animate({
      scrollTop: a.offset().top-3
    }, 250);
  }

  var rrow = $("#result-row");
  var extraMargin = 40;
  var endOfPreview =  a.offset().top + preview.height() + extraMargin;
  var endOfRow = rrow.height() + rrow.offset().top;
  if (endOfPreview > endOfRow) {
    // only enlarge the margin - otherwise the page scrolls back
    rrow.css("margin-bottom", endOfPreview - endOfRow + extraMargin);
  }
}

function previewSuccess(data, force) {
  $("#preview_container_in").html(data);
  var a = $(".current_preview");
  var td = a.parent();

  var a_index = td.children(".links_a").index(a);

  // a width = 64
  var as_per_row = Math.floor(td.width() / 64);
  var full_top_rows = Math.ceil((a_index+1) / as_per_row);
  var preview_offset = (as_per_row * full_top_rows) - 1;
  var as_count = td.children(".links_a").length - 1;
  if (as_count < preview_offset) {
    preview_offset = as_count;
  }

  var pout = $("#preview_container_out");
  // make it visible so jquery gets the props right
  pout.insertAfter(td.children(".links_a").eq(preview_offset));

  var pin = $("#preview_container_in");
  if (!(pin.find("pre").length || pin.find("audio").length)) {
    window.differ = new NeedleDiff("needle_diff", 1024, 768);
    setDiffScreenshot(window.differ, $("#preview_container_in #step_view").data("image"));
    setNeedle();
  }
  pin.css("left", -($(".result").width()+$(".component").width()+2*16));
  var tdWidth = $(".current_preview").parents("td").width();
  pout.width(tdWidth).hide().fadeIn({
    duration: (force?0:150),
    complete: function() {
      checkPreviewVisible(a, pin);
    }
  });
  $('[data-toggle="popover"]').popover({html: true});
  // make persistent dropdowns persistent by preventing click-event propagation
  $('.dropdown-persistent').on('click', function (event) {
      event.stopPropagation();
  });
  // ensure keydown event happening when button has focus is propagated to the right handler
  $('.candidates-selection .dropdown-toggle').on('keydown', function (event) {
      event.stopPropagation();
      handleKeyDownOnTestDetails(event);
  });
  // handle click on the diff selection
  $('.trigger-diff').on('click', function (event) {
      var trigger = $(this);
      setNeedle(trigger.parents('tr'), trigger.data('diff'));
      event.stopPropagation();
  });
}

function mapHash(hash) {
  return (hash === "#details" || hash.length < 2) ? "#" : hash;
}

function setResultHash(hash, replace) {
  // the details tab is the real page
  hash = mapHash(hash);
  var locationhash = mapHash(window.location.hash);
  if (locationhash === hash) { return; }
  if (replace && history.replaceState) {
    history.replaceState(null, null, hash);
  } else if (!replace && history.pushState) {
    history.pushState(null, null, hash);
  } else {
    location.hash = hash;
  }
}

function setCurrentPreview(a, force) {
  if ((a && a.length && !a.is(".current_preview")) || force) {
    // show
    $(".current_preview").removeClass("current_preview");

    var link = a.find("a");
    if (!link || !link.data("url")) {
      return;
    }
    a.addClass("current_preview");
    setResultHash(link.attr("href"), true);
    $.get({ url: link.data("url"),
            success: function(data) {
              previewSuccess(data, force);
            }
          }).fail(function() { setCurrentPreview(null); });
  }
  else {
    // hide
    if ($("#preview_container_out").is(":visible")) {
      $("#preview_container_out").fadeOut(150);
      $(".current_preview").removeClass("current_preview");
      setResultHash("", true);
    }
  }
}

function nextPreview() {
  var a = $(".current_preview");
  if(a) {
    var table = $(".current_preview").parents("table");
    var a_index = table.find(".links_a").index(a);
    var next_a = a_index + 1;
    var b = table.find(".links_a").eq(next_a);
    if (b.length) {
      setCurrentPreview(b);
    }
  }
}

function prevPreview() {
  var a = $(".current_preview");
  if (a) {
    var table = $(".current_preview").parents("table");
    var a_index = table.find(".links_a").index(a);
    var next_a = a_index - 1;
    if (next_a >= 0) {
      var b = table.find(".links_a").eq(next_a);
      if (b.length) {
        setCurrentPreview(b);
      }
    }
  }
}

function checkResultHash() {
  var hash = window.location.hash;
  if (!hash || hash == "#") {
    hash = "#details";
  }
  var link = $("[href='" + hash + "']");
  if (link && link.attr("role") === "tab") {
    if (!link.prop("aria-expanded")) {
      link.tab("show");
    }
  }
  if (hash.search("#step/") == 0) {
    var detailstab = $("[href='#details']");
    detailstab.tab("show");
    if (link && !link.parent().is(".current_preview")) {
      setCurrentPreview(link.parent());
    } else if (!link) {
      setCurrentPreview(null);
    }
  } else if (hash.search("#comment-") == 0) {
    $("[href='#comments']").tab("show");
  } else {
    // reset
    setCurrentPreview(null);
  }
}

function prevNeedle() {
    // select previous in current tag
    var currentSelection = $('#needlediff_selector tbody tr.selected');
    var newSelection = currentSelection.prev();
    if (!newSelection.length) {
        // select last in previous tag
        newSelection = currentSelection.parents('li').prevAll().find('tbody tr').last();
    }
    setNeedle(newSelection);
}

function nextNeedle() {
    var currentSelection = $('#needlediff_selector tbody tr.selected');
    if (!currentSelection.length) {
        // select first needle in first tag
        var newSelection = $('#needlediff_selector tbody tr:first-child').first();
    } else {
        // select next in current tag
        var newSelection = currentSelection.next();
        if (!newSelection.length) {
            // select first of next tag
            newSelection = currentSelection.parents('li').nextAll().find('tbody tr').first();
        }
    }
    if (newSelection.length) {
        setNeedle(newSelection);
    }
}

function handleKeyDownOnTestDetails(e) {
    var ftn = $(':focus').prop('tagName');
    if (ftn === 'INPUT' || ftn === 'TEXTAREA') {
        return;
    }
    if (e.shiftKey || e.metaKey || e.ctrlKey || e.altKey) {
        return;
    }

    switch(e.which) {
        case KeyEvent.DOM_VK_LEFT:
            prevPreview();
            e.preventDefault();
            break;
        case KeyEvent.DOM_VK_RIGHT:
            nextPreview();
            e.preventDefault();
            break;
        case KeyEvent.DOM_VK_ESCAPE:
            setCurrentPreview(null);
            e.preventDefault();
            break;
        case KeyEvent.DOM_VK_UP:
            prevNeedle();
            e.preventDefault();
            break;
        case KeyEvent.DOM_VK_DOWN:
            nextNeedle();
            e.preventDefault();
            break;
    }
}

function setupResult(state, jobid, status_url, details_url) {
  setupAsyncFailedResult();
  $(".current_preview").removeClass("current_preview");

  $(window).keydown(handleKeyDownOnTestDetails);

  $(window).resize(function() {
    if ($(".current_preview")) {
      setCurrentPreview($(".current_preview"), true);
    }
  });

  $(document).on('click', '.links_a > a', function() {
    setCurrentPreview($(this).parent());
    return false;
  });

  // don't overwrite the tab if coming from the URL (ignore '#')
  if (location.hash.length < 2 && state === "scheduled") {
    setResultHash("#settings", true);
  }
  // This could be easily rewritten as $.inArray
  if ( state == "running"   ||
       state == "waiting"   ||
       state == "uploading" ||
       state == "assigned"  ||
       state == "setup" ) {
    setupRunning(jobid, status_url, details_url);
  }
  else if (state == "scheduled") {
    // reload when test starts
    window.setInterval(function() {
      $.ajax(status_url).done(function(newStatus) {
        if (newStatus.state != 'scheduled') {
          setTimeout(function() {location.href = location.href.replace(/#.*/, '');}, 1000);
        }
      });
    }, 10000);
  }
  $(window).on("hashchange", checkResultHash);
  checkResultHash();

  $("a[data-toggle='tab']").on("show.bs.tab", function(e) {
    var tabshown = $(e.target).attr("href");
    // now this is very special
    if (window.location.hash.search("#step/") == 0 && tabshown == "#details" ) {
      return;
    }
    setResultHash(tabshown);
  });

  // define handler for tab switch to resume/pause live view depending on whether it is the
  // current tab
  $('#result-row a[data-toggle="tab"]').on('shown.bs.tab', function(e) {
    if (e.target.hash === '#live') {
      resumeLiveView();
    } else {
      pauseLiveView();
    }
  });
}
