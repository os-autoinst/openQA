document.observe('dom:loaded', function() {

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

  var target;
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
      var c = confirm('Job clonned into #'+jobid+'. Confirm to visit that job. Cancel to be redirected to the results of the interrupted one.');
      if (c) {
        var url = document.URL.substring(0, document.URL.lastIndexOf("/") + 1) + jobid;
        window.location = url;
      } else {
        // We need to wait a little bit before accessing the results
        setTimeout(function() {location.reload();}, 5000);
      }
    });
  }

  $$('a.prio-down').each(function(element) {
    element.on('click', function(event) {
      window.adjustPriority($(this), -10);
      event.stop();
    });
  });

  $$('a.prio-up').each(function(element) {
    element.on('click', function(event) {
      window.adjustPriority($(this), 10);
      event.stop();
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
