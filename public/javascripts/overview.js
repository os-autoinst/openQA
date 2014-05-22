document.on('ajax:success', 'a', function(event, element) {
  var span = $('res-' + element.dataset.jobid);

  // Close the dialog
  span.retrieve('opentips')[0].hide();

  // After canceling
  if (element.hasClassName('cancel')) {
    span.update('cancelled');
    new Effect.Highlight(span);

  // After adjusting priority
  } else if (element.hasClassName('prio')) {
    var prio = element.href.toQueryParams().prio;
    span.update('sched.('+prio+')');
    new Effect.Highlight(span);
  }
});
