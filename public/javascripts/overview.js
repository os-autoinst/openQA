document.on('ajax:success', function(event) {
  // We only have to care about 'cancel' right now since the other calls are still
  // not AJAX (WIP)
  var span = $('res-' + event.memo.responseJSON.name);
  span.retrieve('opentips')[0].hide();
  span.update('cancelled');
  new Effect.Highlight(span);
});
