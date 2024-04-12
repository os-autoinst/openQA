var disablePermanently = false;

function dismissPernamently(checkboxElement) {
  disablePermanently = checkboxElement.checked;
}

function postFeature(latestFeature) {
  $.ajax({
    url: urlWithBase('/api/v1/feature'),
    method: 'POST',
    data: {version: disablePermanently ? 0 : latestFeature}
  });
}

function newFeature(featureVersion) {
  // don't show tour if dismissed or latest feature already seen
  const latestFeature = 4;
  if (featureVersion <= 0 || featureVersion >= latestFeature) {
    return;
  }
  const tour = new Shepherd.Tour({
    defaultStepOptions: {
      cancelIcon: {
        enabled: true
      },
      confirmCancel: true
    }
  });
  tour.addSteps([
    {
      title: 'All tests area',
      text: "<p>In this area all tests are provided and grouped by the current state. You can see which jobs are running, scheduled or finished.</p><div class='checkbox'><label><input type='checkbox' id='dont-notify' onchange='dismissPernamently(this)'> Don't notify me anymore (permanent)</label></div>",
      attachTo: {
        element: '#all_tests',
        on: 'bottom'
      },
      buttons: [
        {
          text: 'Next',
          action: tour.next,
          classes: 'btn btn-default '
        }
      ],
      when: {
        cancel: function () {
          postFeature(latestFeature);
        }
      },
      id: 'step-0'
    },
    {
      title: 'Job group menu',
      text: "<p>Access the job group overview pages from here. Besides test results, a description and commenting area are provided.</p><div class='checkbox'><label><input type='checkbox' id='dont-notify' onchange='dismissPernamently(this)'> Don't notify me anymore (permanent)</label></div>",
      attachTo: {
        on: 'bottom',
        element: '#job_groups'
      },
      buttons: [
        {
          text: 'Prev',
          action: tour.back,
          classes: 'btn btn-default '
        },
        {
          text: 'Next',
          action: tour.next,
          classes: 'btn btn-default '
        }
      ],
      when: {
        cancel: function () {
          postFeature(latestFeature);
        }
      },
      id: 'step-1'
    },
    {
      title: 'User menu',
      text: "<p>Access your user menu from here.</p><div class='checkbox'><label><input type='checkbox' id='dont-notify' onchange='dismissPernamently(this)'> Don't notify me anymore (permanent)</label></div>",
      attachTo: {
        element: '#user-action',
        on: 'bottom'
      },
      buttons: [
        {
          text: 'Prev',
          action: tour.back,
          classes: 'btn btn-default '
        },
        {
          text: 'Next',
          action: tour.next,
          classes: 'btn btn-default '
        }
      ],
      when: {
        cancel: function () {
          postFeature(latestFeature);
        }
      },
      id: 'step-2'
    },
    {
      title: 'Activity View',
      text: "<p>Access the activity view from the operators menu. This view gives you an overview of your current jobs.</p><div class='checkbox'><label><input type='checkbox' id='dont-notify' onchange='dismissPernamently(this)'> Don't notify me anymore (permanent)</label></div>",
      attachTo: {
        element: '#activity_view'
      },
      buttons: [
        {
          text: 'Prev',
          action: tour.back,
          classes: 'btn btn-default '
        }
      ],
      when: {
        cancel: function () {
          postFeature(latestFeature);
        }
      },
      id: 'step-3'
    }
  ]);
  tour.start();
}
