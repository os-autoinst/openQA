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
    var commentstab = $("[href='#comments']");
    commentstab.tab("show");
  } else {
    // reset
    setCurrentPreview(null);
  }
}

function setupResult(state, jobid, status_url, details_url) {
  setupAsyncFailedResult();
  $(".current_preview").removeClass("current_preview");

  $(window).keydown(function(e) {
    var ftn = $(":focus").prop("tagName");
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
      setCurrentPreview(null);
      e.preventDefault();
    }
  });

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
  if (location.hash.length < 2) {
    if (state == "scheduled") {
      setResultHash("#settings", true);
    } else if (state == "running" || state == "waiting") {
      if (window.location.href.substr(-1) != "#") {
        setResultHash("#live", true);
      }
    }
  }
  if (state == "running" || state == "waiting" || state == "uploading") {
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

  $(document).on("change", "#needlediff_selector", setNeedle);
  $("a[data-toggle='tab']").on("show.bs.tab", function(e) {
    var tabshown = $(e.target).attr("href");
    // now this is very special
    if (window.location.hash.search("#step/") == 0 && tabshown == "#details" ) {
      return;
    }
    setResultHash(tabshown);
  });
}

$(document).ready(function() {
    $.ajax({
        url: sessionStorage.getItem('openQA.requestURL'),
        type: 'GET',
        dataType: 'json',
        success: function(resp) {
            for (var i = 0; i < resp.modules.length; i++) {
                if (resp.modules[i].result != 'passed') {
                    showThumbnailsForModule(i, resp.modules[i]);
                }
            }
        }
    });
});

function setupUrls(audio_icon_url, terminal_icon_url, request_url) {
    sessionStorage.setItem('openQA.audioIconURL', audio_icon_url);
    sessionStorage.setItem('openQA.terminalIconURL', terminal_icon_url);
    sessionStorage.setItem('openQA.requestURL', request_url);
}

function onClickShowThumbnails(moduleNumber) {
    $.ajax({
        url: sessionStorage.getItem('openQA.requestURL'),
        type: 'GET',
        dataType: 'json',
        success: function(resp) {
            showThumbnailsForModule(moduleNumber, resp.modules[moduleNumber]);
        }
    });
}

function showThumbnailsForModule(moduleNumber, moduleObj) {
    var stepBegin = "<div class=\"links_a\"><div class=\"fa fa-caret-down\"></div><a class=\"no_hover\" data-url=\"";
    var moduleHTML = " ";
    var audio_icon_url = sessionStorage.getItem('openQA.audioIconURL');
    var terminal_icon_url = sessionStorage.getItem('openQA.terminalIconURL');
    for (var i = 0; i < moduleObj.details.length; i++) {
        var step = moduleObj.details[i];
        var href = "#step/" + moduleObj.name + "/" + step.num;
        var title = step.text ? step.title : step.name;
        moduleHTML += stepBegin + step.dataurl + "\"href=\"" + href + "\">";
        if (step.screenshot) {
            moduleHTML += step.thumbnail;
        } else if (step.audio) {
            moduleHTML += "<img src=\"" + audio_icon_url + "\" width=\"60\" height=\"45\" alt=\"" + step.name + "\" class=\"resborder resborder_" + step.result + "\"/>";
        } else if (step.text) {
            if (step.title == "wait_serial") {
                moduleHTML += "<img src=\"" + terminal_icon_url + "\" width=\"60\" height=\"45\" alt=\"" + step.name + "\" class=\"resborder resborder_" + step.result + "\/>";
            } else {
                moduleHTML += "<span class=\"resborder resborder_" + step.result + "\"";
                moduleHTML += step.title ? step.title : 'Text';
                moduleHTML += "</span>";
            }
        }
        moduleHTML += "</a></div>";
    }
    document.getElementById("module" + moduleNumber).innerHTML = moduleHTML;
}