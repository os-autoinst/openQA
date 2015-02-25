document.observe('dom:loaded', function() {
  var target;

  $$('#results td.cancel a').each(function(element) {
    element.on('ajax:success', 'tr', function(event, row) {
      new Effect.Fade(row);
    });
  });

  $$('#results td.clone a').each(function(element) {
    element.on('ajax:success', 'td', function(event, cell) {
      var jobid = event.memo.responseJSON.result[0];
      cell.update('<a href="/tests/'+jobid+'">#'+jobid+'</a>');
      new Effect.Highlight(cell);
    });
  });

  // Init the counter
  window.updateListCounter();

  $$('#results input[name=jobs]').each(function(element) {
    element.on('click', window.updateListCounter)
  });

  if (target = $('list-restart')) {
    target.on('click', function(event) {
      event.stop(); // Don't follow the link
      // Submit the form, but using AJAX, and reload afterwards
      // (assign window.location instead of reload() to reset forms)
      $('list-form').request({
        onComplete: function() { window.location = document.URL }
      });
    });
  }

  if (target = $('list-select')) {
    target.on('click', function(event) {
      event.stop(); // Don't follow the link
      $$('#results tbody tr').select(Element.visible).each(function(e) {
        e.select('input[name=jobs]')[0].checked=true
      });
      window.updateListCounter();
    });
  }

  if (target = $('list-unselect')) {
    target.on('click', function(event) {
      event.stop(); // Don't follow the link
      $$('#results tbody tr').select(Element.visible).each(function(e) {
        e.select('input[name=jobs]')[0].checked=false
      });
      window.updateListCounter();
    });
  }

  if (target = $('cancel_running')) {
    target.on('ajax:success', function(event) {
      // Let's bother the user to have time to really cancel
      alert('Job canceled. Postprocessing. You will be redirected to the results page in a few seconds.');
      // Even though, it will most likely not be enough
      setTimeout(function() {location.reload();}, 5000);
    });
  }

  if (target = $('restart_running')) {
    target.on('ajax:success', function(event) {
      var jobid = event.memo.responseJSON.result[0];
      var c = confirm('Job cloned into #'+jobid+'. Confirm to visit that job. Cancel to be redirected to the results of the interrupted one.');
      if (c) {
        var url = document.URL.substring(0, document.URL.lastIndexOf("/") + 1) + jobid;
        window.location = url;
      } else {
        // We need to wait a little bit before accessing the results
        setTimeout(function() {location.reload();}, 5000);
      }
    });
  }

  if (target = $('restart-result')) {
    target.on('ajax:success', 'a', function(event, element) {
      var jobid = event.memo.responseJSON.result[0];
      event.stop(); // Don't follow the link
      // If the API call returns a id, a new job have been created.
      // If not, nothing happened (or the old job is being reused).
      if (jobid) {
        var cell;
        if (cell = $('clone')) {
          cell.update('<a href="/tests/'+jobid+'">'+jobid+'</a>');
          new Effect.Highlight(cell);
        }
      }
      new Effect.Fade(element);
    });
  }

  $$('a.prio-down').each(function(element) {
    element.on('click', function(event) {
      window.adjustPriority($(this), -10);
      event.stop(); // Don't follow the link
    });
  });

  $$('a.prio-up').each(function(element) {
    element.on('click', function(event) {
      window.adjustPriority($(this), 10);
      event.stop(); // Don't follow the link
    });
  });


});

// Before sending the AJAX request, the updated priority must be calculated.
function adjustPriority(element, amount) {
  var prioHolder = element.up(1).select('[data-prio]')[0];
  var prio = parseInt(prioHolder.dataset.prio) + amount;
  var url = element.href.substring(0, element.href.lastIndexOf("?") + 1) + 'prio='+prio;
  new Ajax.Request(url, {
    method: 'post',
    onSuccess: function(r) { prioHolder.replace('<span data-prio="'+prio+'">'+prio+'</span> '); }
  });
}

// Update the counter of selected items in the jobs list
function updateListCounter() {
  var counter;
  if (counter = $('list-counter')) {
    counter.update($$('input[name=jobs]:checked').length);
  }
}
