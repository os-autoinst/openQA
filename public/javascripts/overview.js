document.on('ajax:success', 'a', function(event, element) {
  var json = event.memo.responseJSON;
  var span = $('res-' + json.id);
  span.retrieve('opentips')[0].hide();
  if (element.hasClassName('cancel')) {
    span.update('cancelled');
    new Effect.Highlight(span);
  } else if (element.hasClassName('prio')) {
    span.update('sched.('+json.priority+')');
    new Effect.Highlight(span);
  }
});
