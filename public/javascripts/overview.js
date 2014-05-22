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

  // After re-scheduling
  } else if (element.hasClassName('restart')) {
    var oldId = span.dataset.ot;
    var newId = event.memo.responseJSON.result[0];
    var prio = element.dataset.prio;

    // If the API call returns a new id, a new job have been created to replace
    // the old one. In other case, the old job is being reused
    if (newId) {
      span.id = 'res-'+newId;
      span.dataset.ot = newId;
      var newUrl = span.dataset.otAjax.replace(oldId, newId);
      span.dataset.otAjax = newUrl; // Not really effective
      span.retrieve('opentips')[0].options.ajax = newUrl; // This works
    }

    // Remove all previous styling information
    var classArray = span.classNames().toArray();
    for (var index = 0, len = classArray.size(); index < len; ++index) {
      span.removeClassName(classArray[index]);
    }
    span.update('sched.('+prio+')');
    new Effect.Highlight(span);
  }
});
