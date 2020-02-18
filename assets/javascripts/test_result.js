/* jshint multistr: true */
/* jshint esversion: 6 */

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

function insertPreviewContainer(previewContainer, previewLink) {
  var td = previewLink.parent();
  var links = td.children(".links_a");
  var a_index = links.index(previewLink);
  var as_per_row = Math.floor(td.width() / 64); // previewLink width is 64
  var full_top_rows = Math.ceil((a_index+1) / as_per_row);
  var preview_offset = (as_per_row * full_top_rows) - 1;
  var as_count = links.length - 1;
  if (as_count < preview_offset) {
    preview_offset = as_count;
  }
  previewContainer.insertAfter(links.eq(preview_offset));
}

function previewSuccess(data, force) {
  // find the outher and inner preview container
  var pin = $("#preview_container_in");
  var pout = $("#preview_container_out");
  if (!pin.length || !pout.length) {
      console.error('showing preview/needle diff: Preview container not found');
      return;
  }

  pin.html(data);

  // insert the outher preview container after the right preview link
  var previewLink = $(".current_preview");
  insertPreviewContainer(pout, previewLink);

  if (!(pin.find("pre").length || pin.find("audio").length)) {
    window.differ = new NeedleDiff("needle_diff", 1024, 768);
    var imageSource = pin.find("#step_view").data("image");
    if (!imageSource) {
        console.error('showing preview/needle diff: No image source found');
        return;
    }
    setDiffScreenshot(window.differ, imageSource);
    setNeedle();
  }
  pin.css("left", -($(".result").width()+$(".component").width()+2*16));
  var tdWidth = $(".current_preview").parents("td").width();
  pout.width(tdWidth).hide().fadeIn({
    duration: (force?0:150),
    complete: function() {
      checkPreviewVisible(previewLink, pin);
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

// not sure if the following would break identifying the right route or
// document for lazy loading
//function mapHash(hash) {
//  return (hash === "#details" || hash.length < 2) ? "#" : hash;
//}

function setResultHash(hash, replace) {
  // the details tab is the real page
  //hash = mapHash(hash);
  //var locationhash = mapHash(window.location.hash);
  //if (locationhash === hash) { return; }
  if (replace && history.replaceState) {
    history.replaceState(null, null, hash);
  } else if (!replace && history.pushState) {
    history.pushState(null, null, hash);
  } else {
    location.hash = hash;
  }
}

function toggleTextPreview(textResultDomElement) {
    var textResultElement = $(textResultDomElement).parent();
    if (textResultElement.hasClass('current_preview')) {
        // skip if current selection has selected text
        var selection = window.getSelection();
        if (!selection.isCollapsed && $.contains(textResultDomElement, selection.anchorNode)) {
            return;
        }
        // hide current selection (selected element has been clicked again)
        setCurrentPreview(undefined);
    } else {
        // show new selection, ensure current selection is hidden
        setCurrentPreview(textResultElement);
    }
}

function hidePreviewContainer() {
    var previewContainer = $('#preview_container_out');
    if (previewContainer.is(':visible')) {
        previewContainer.fadeOut(150);
    }
}

function setCurrentPreview(a, force) {
    // just hide current preview
    if (!(a && a.length && !a.is('.current_preview')) && !force) {
        $('.current_preview').removeClass('current_preview');
        hidePreviewContainer();
        setResultHash('', true);
        return;
    }

    // unselect previous preview
    $('.current_preview').removeClass('current_preview');

    // show preview for results with text data
    var textResultElement = a.find('span.text-result');
    if (textResultElement.length) {
        a.addClass('current_preview');
        hidePreviewContainer();
        setResultHash(textResultElement.data('href'), true);

        // ensure element is in viewport
        var aOffset = a.offset().top;
        if (aOffset < window.scrollY || (aOffset + a.height()) > (window.scrollY + window.innerHeight)) {
            $('html').animate({
                scrollTop: aOffset
            }, 500);
        }
        return;
    }

    // show preview for other/regular results
    var link = a.find('a');
    if (!link || !link.data('url')) {
        return;
    }
    a.addClass('current_preview');
    setResultHash(link.attr('href'), true);
    $.get({ url: link.data('url'),
            success: function(data) {
              previewSuccess(data, force);
            }
    }).fail(function() {
        console.warn('Failed to load data from: ' + link.data('url'));
        setCurrentPreview(null);
    });
}

function selectPreview(which) {
    var currentPreview = $('.current_preview');
    var linkContainer = currentPreview[which]();
    // skip possibly existing elements between the preview links (eg. the preview container might be between)
    while (linkContainer.length && !linkContainer.hasClass('links_a')) {
        linkContainer = linkContainer[which]();
    }
    // select next/prev detail in current step
    if (linkContainer.length) {
        setCurrentPreview(linkContainer);
        return;
    }
    // select first/last detail in next/prev module
    var linkSelector = '.links_a:' + (which === 'next' ? 'first' : 'last');
    var row = currentPreview.parents('tr');
    for (;;) {
        row = row[which]();
        if (!row.length) {
            return;
        }
        linkContainer = row.find(linkSelector);
        if (linkContainer.length) {
            setCurrentPreview(linkContainer);
            return;
        }
    }
}

function nextPreview() {
    selectPreview('next');
}

function prevPreview() {
    selectPreview('prev');
}

function checkResultHash() {
    var hash = window.location.hash;

    // default to 'Details' tab
    if (!hash || hash == '#') {
        hash = '#details';
    }

    // check for links or text details matching the hash
    var link = $("[href='" + hash + "'], [data-href='" + hash + "']");
    if (link && link.attr("role") === 'tab' && !link.prop('aria-expanded')) {
        link.tab('show');
    } else if (hash.search('#step/') === 0) {
        // show details tab for steps
        $("[href='#details']").tab('show');
        // show preview or text details
        if (link && !link.parent().is(".current_preview")) {
            setCurrentPreview(link.parent());
        } else if (!link) {
            setCurrentPreview(null);
        }
    } else if (hash.search('#comment-') === 0) {
        // show comments tab if anchor contains specific comment
        $("[href='#comments']").tab('show');
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
    var newSelection;
    if (!currentSelection.length) {
        // select first needle in first tag
        newSelection = $('#needlediff_selector tbody tr:first-child').first();
    } else {
        // select next in current tag
        newSelection = currentSelection.next();
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
    if (e.metaKey || e.ctrlKey || e.altKey) {
        return;
    }

    switch(e.which) {
        case KeyEvent.DOM_VK_LEFT:
            if (!e.shiftKey) {
                prevPreview();
                e.preventDefault();
            }
            break;
        case KeyEvent.DOM_VK_RIGHT:
            if (!e.shiftKey) {
                nextPreview();
                e.preventDefault();
            }
            break;
        case KeyEvent.DOM_VK_ESCAPE:
            if (!e.shiftKey) {
                setCurrentPreview(null);
                e.preventDefault();
            }
            break;
        case KeyEvent.DOM_VK_UP:
            if (e.shiftKey) {
                prevNeedle();
                e.preventDefault();
            }
            break;
        case KeyEvent.DOM_VK_DOWN:
            if (e.shiftKey) {
                nextNeedle();
                e.preventDefault();
            }
            break;
    }
}

function setupTab(tabHash) {
    if (tabHash === '#details') {
        setupDetails();
    } else if (tabHash === '#dependencies') {
        setupDependencyGraph();
    } else if (tabHash === '#investigation') {
        setupInvestigation();
    } else if (tabHash === '#external') {
        setupExternalResults();
    }
    if (tabHash === '#live') {
        setupDeveloperPanel();
        resumeLiveView();
    } else {
        pauseLiveView();
    }
}

function setupDetails() {
    var element = document.getElementById('details_content');
    //if (element.dataset.initialized) {
        //return;
    //}
    $.ajax({
        url: element.dataset.url,
        method: 'GET',
        success: function(response) {
            element.innerHTML = response;
        },
        error: function(xhr, ajaxOptions, thrownError) {
            $(element).text('Unable to get details info: ' + thrownError);
        }
    });
}

function setupInvestigation() {
    var element = document.getElementById('investigation_status');
    if (element.dataset.initialized) {
        return;
    }
    $.ajax({
        url: element.dataset.url,
        method: 'GET',
        success: function(response) {
            if (typeof response !== 'object') {
                element.innerHTML = 'Investigation info returned by server is invalid.';
                return;
            }

            var theadElement = document.createElement('thead');
            var headTrElement = document.createElement('tr');
            var headThElement = document.createElement('th');
            headThElement.appendChild(document.createTextNode('Investigation'));
            headThElement.colSpan = 2;
            headTrElement.appendChild(headThElement);
            theadElement.appendChild(headTrElement);

            var tbodyElement = document.createElement('tbody');
            Object.keys(response).forEach(key => {
                var keyElement = document.createElement('td');
                keyElement.style.verticalAlign = 'top';
                keyElement.appendChild(document.createTextNode(key));

                var valueElement = document.createElement('td');
                var preElement = document.createElement('pre');
                preElement.appendChild(document.createTextNode(response[key]));
                valueElement.appendChild(preElement);

                var trElement = document.createElement('tr');
                trElement.appendChild(keyElement);
                trElement.appendChild(valueElement);
                tbodyElement.appendChild(trElement);
            });

            var tableElement = document.createElement('table');
            tableElement.id = 'investigation_status_entry';
            tableElement.className = 'infotbl table table-striped';
            tableElement.appendChild(theadElement);
            tableElement.appendChild(tbodyElement);
            element.innerHTML = '';
            element.appendChild(tableElement);
            element.dataset.initialized = true;
        },
        error: function(xhr, ajaxOptions, thrownError) {
            $(element).text('Unable to get investigation info: ' + thrownError);
        }
    });
}

function setupExternalResults() {
    var externalTable = $('#external-table');
    // skip if table is not present (meaning no external results available) or if the table has
    // already been initialized
    if (!externalTable.length || externalTable.data('initialized')) {
        return;
    }

    // make the table use DataTable
    externalTable.data('initialized', true);
    externalTable = externalTable.DataTable({
        lengthMenu: [[10, 25, 50, 100], [10, 25, 50, 100]],
        order: [],
    });

    // setup filtering
    var onlyFailedCheckbox = $('#external-only-failed-filter');
    onlyFailedCheckbox.change(function(event) {
        externalTable.draw();
    });
    $.fn.dataTable.ext.search.push(function(settings, data, dataIndex) {
        // don't apply filter if checkbox not checked
        if (!onlyFailedCheckbox.prop('checked')) {
            return true;
        }
        // filter out everything but failures and softfailures
        var rowData = externalTable.row(dataIndex).data();
        if (!rowData) {
            return false;
        }
        var result = rowData[2];
        return result && (result.indexOf('result_fail') > 0 || result.indexOf('result_softfail') > 0);
    });
}

function setupResult(state, jobid, status_url, details_url) {
  testStatus.job_state_when_loading_page = state;

  // load embedded logfiles
  $('.embedded-logfile').each(function(index, logFileElement) {
    $.ajax(logFileElement.dataset.src).done(function(response) {
      logFileElement.innerHTML = response;
    }).fail(function(jqXHR, textStatus, errorThrown) {
      logFileElement.innerHTML = 'Unable to load logfile: ' + errorThrown;
    });
  });

  setupLazyLoadingFailedSteps();
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
  if (location.hash.length < 2 && (state === 'scheduled' || state === 'assigned')) {
    setResultHash("#settings", true);
  }
  if (state !== 'done') {
    setupRunning(jobid, status_url, details_url);
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

  // setup lazy-loading for tabs
  setupTab(window.location.hash);
  $('#result-row a[data-toggle="tab"]').on('shown.bs.tab', function(e) {
    setupTab(e.target.hash);
  });

  // setup result filter, define function to apply filter changes
  var detailsFilter = $('#details-filter');
  var detailsNameFilter = $('#details-name-filter');
  var detailsFailedOnlyFilter = $('#details-only-failed-filter');
  var resultsTable = $('#results');
  var anyFilterEnabled = false;
  var applyFilterChanges = function(event) {
      // determine enabled filter
      anyFilterEnabled = !detailsFilter.hasClass('hidden');
      if (anyFilterEnabled) {
          var nameFilter = detailsNameFilter.val();
          var nameFilterEnabled = nameFilter.length !== 0;
          var failedOnlyFilterEnabled = detailsFailedOnlyFilter.prop('checked');
          anyFilterEnabled = nameFilterEnabled || failedOnlyFilterEnabled;
      }

      // show everything if no filter present
      if (!anyFilterEnabled) {
          resultsTable.find('tbody tr').show();
          return;
      }

      // hide all categories
      resultsTable.find('tbody tr td[colspan="3"]').parent('tr').hide();

      // show/hide table rows considering filter
      $.each(resultsTable.find('tbody .result'), function(index, td) {
          var tdElement = $(td);
          var trElement = tdElement.parent('tr');
          var stepMaches = (
              (!nameFilterEnabled ||
                trElement.find('td.component').text().indexOf(nameFilter) >= 0) &&
                (!failedOnlyFilterEnabled ||
                    tdElement.hasClass('resultfailed') ||
                    tdElement.hasClass('resultsoftfailed'))
          );
          trElement[stepMaches ? 'show' : 'hide']();
      });
  };

  detailsNameFilter.keyup(applyFilterChanges);
  detailsFailedOnlyFilter.change(applyFilterChanges);

  // setup filter toggle
  $('.details-filter-toggle').on('click', function(event) {
      event.preventDefault();
      detailsFilter.toggleClass('hidden');
      applyFilterChanges();
  });
}

function renderDependencyGraph(container, nodes, edges, cluster, currentNode) {
    // create a new directed graph
    var g = new dagreD3.graphlib.Graph({ compound:true }).setGraph({});

    // set left-to-right layout and spacing
    g.setGraph({
        rankdir: "LR",
        nodesep: 10,
        ranksep: 50,
        marginx: 10,
        marginy: 10,
    });

    // insert nodes
    nodes.forEach(node => {
        var testResultId;
        if (node.result !== 'none') {
            testResultId = node.result;
        } else {
            testResultId = node.state;
            if (testResultId === 'scheduled' && node.blocked_by_id) {
                testResultId = 'blocked';
            }
        }
        var testResultName = testResultId.replace(/_/g, ' ');

        g.setNode(node.id, {
            label: function() {
                var table = document.createElement("table");
                table.id = 'nodeTable' + node.id;
                var tr = d3.select(table).append("tr");

                var testNameTd = tr.append("td");
                if (node.id == currentNode) {
                    testNameTd.text(node.label);
                    tr.node().className = 'current';
                } else {
                    var testNameLink = testNameTd.append("a");
                    testNameLink.attr('href', '/tests/' + node.id);
                    testNameLink.text(node.label);
                }

                var testResultTd = tr.append("td");
                testResultTd.text(testResultName);
                testResultTd.node().className = testResultId;

                return table;
            },
            padding: 0,
            name: node.name,
            testResultId: testResultId,
            testResultName: testResultName,
            startAfter: node.chained,
            startDirectlyAfter: node.directly_chained,
            parallelWith: node.parallel,
        });
    });

    // insert edges
    edges.forEach(edge => {
        g.setEdge(edge.from, edge.to, {});
    });

    // insert clusters
    Object.keys(cluster).forEach(clusterId => {
        g.setNode(clusterId, {});
        cluster[clusterId].forEach(child => {
            g.setParent(child, clusterId);
        });
    });

    // create the renderer
    var render = new dagreD3.render();

    // set up an SVG group so that we can translate the final graph.
    var svg = d3.select('svg'), svgGroup = svg.append('g');

    // run the renderer (this is what draws the final graph)
    render(svgGroup, g);

    // add tooltips
    svgGroup.selectAll('g.node')
        .attr('title', function(v) {
            var node = g.node(v);
            var tooltipText = '<p>' + node.name + '</p>';
            var startAfter = node.startAfter;
            var startDirectlyAfter = node.startDirectlyAfter;
            var parallelWith = node.parallelWith;
            if (startAfter.length || startDirectlyAfter.length || parallelWith.length) {
                tooltipText += '<div style="border-top: 1px solid rgba(100, 100, 100, 30); margin: 5px 0px;"></div>';
                if (startAfter.length) {
                    tooltipText += '<p><code>START_AFTER_TEST=' + htmlEscape(startAfter.join(',')) + '</code></p>';
                }
                if (startDirectlyAfter.length) {
                    tooltipText += '<p><code>START_DIRECTLY_AFTER_TEST=' + htmlEscape(startDirectlyAfter.join(',')) + '</code></p>';
                }
                if (parallelWith.length) {
                    tooltipText += '<p><code>PARALLEL_WITH=' + htmlEscape(parallelWith.join(',')) + '</code></p>';
                }
            }
            return tooltipText;
        })
        .each(function(v) {
            $(this).tooltip({
                html: true,
                placement: 'right',
            });
        });

    // move the graph a bit to the bottom so lines at the top are not clipped
    svgGroup.attr("transform", "translate(0, 20)");

    // set width and height of the svg element to the graph's size plus a bit extra spacing
    svg.attr('width', g.graph().width + 40);
    svg.attr('height', g.graph().height + 40);

    // note: centering is achieved by centering the svg element itself like any other html block element
}

function setupDependencyGraph() {
    if (window.dependencyGraphInitiated) {
        return;
    }
    window.dependencyGraphInitiated = true;

    var statusElement = document.getElementById('dependencygraph_status');
    var containerElement = document.getElementById('dependencygraph');
    $.ajax({
        url: containerElement.dataset.url,
        method: 'GET',
        success: function(dependencyInfo) {
            var nodes = dependencyInfo.nodes;
            var edges = dependencyInfo.edges;
            var cluster = dependencyInfo.cluster;
            if (!nodes || !edges || !cluster) {
                $(statusElement).text('Unable to query dependency info: no nodes/edges received');
                return;
            }
            statusElement.style.textAlign = 'left';
            statusElement.innerHTML = '<p>Arrows visualize chained dependencies specified via <code>START_AFTER_TEST</code> \
                                       and <code>START_DIRECTLY_AFTER_TEST</code> (hover over boxes to distinguish). \
                                       Blue boxes visualize parallel dependencies specified via <code>PARALLEL_WITH</code>. \
                                       The current job is highlighted with a bolder border and yellow background.</p> \
                                       <p>The graph shows only the latest jobs. That means jobs which have been cloned will \
                                       never show up.</p>';
            renderDependencyGraph(containerElement, nodes, edges, cluster, containerElement.dataset.currentJobId);
        },
        error: function(xhr, ajaxOptions, thrownError) {
            $(statusElement).text('Unable to query dependency info: ' + thrownError);
        }
    });
}
