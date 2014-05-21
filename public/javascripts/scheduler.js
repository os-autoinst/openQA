document.observe('dom:loaded', function() {

  $$('#results td.cancel a').each(function(element) {
    element.on('ajax:success', 'tr', function(event, row) {
      Effect.Fade(row);
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
});
