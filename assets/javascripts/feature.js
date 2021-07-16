// jshint esversion: 6

function newFeature(featureVersion) {
  // don't show tour if dismissed or latest feature already seen
  const latestFeature = 4;
  if (featureVersion <= 0 || featureVersion >= latestFeature) {
    return;
  }

  // create tour (see http://bootstraptour.com/api for documentation)
  var tour = new Tour({
    storage: window.localStorage, // necessary for multipage traversal
    template: function () {
      return (
        "<div class='popover tour'>" +
        "<div class='arrow'></div>" +
        "<h3 class='popover-header'></h3>" +
        "<div class='popover-body'></div>" +
        "<div class='popover-navigation'>" +
        "<div class='checkbox'><label><input type='checkbox' id='dont-notify'>Don't notify me anymore (permanent)</label></div>" +
        "<button class='btn btn-default' data-role='prev' id='tour-prev'>« Prev</button>" +
        "<button class='btn btn-default' data-role='next'id='tour-next'>Next »</button>" +
        "<button class='btn btn-default' data-role='end' id='tour-end'>Quit</button>" +
        '</div>' +
        '</div>'
      );
    },
    onShown: function (tour) {
      // allow user to quit the tour at any point and to disable the tour permanently
      $('#tour-end').on('click', function () {
        $.ajax({
          url: '/api/v1/feature',
          method: 'POST',
          data: {version: $('#dont-notify').is(':checked') ? 0 : latestFeature}
        });
      });
    }
  });

  // add steps to the tour
  tour.addSteps([
    {
      element: '#all_tests',
      title: 'All tests area',
      content:
        'In this area all tests are provided and grouped by the current state. You can see which jobs are running, scheduled or finished.',
      placement: 'bottom',
      backdrop: false
    },
    {
      element: '#job_groups',
      title: 'Job group menu',
      content:
        'Access the job group overview pages from here. Besides test results, a description and commenting area are provided.',
      placement: 'bottom',
      backdrop: false
    },
    {
      element: '#user-action',
      title: 'User menu',
      content: 'Access your user menu from here.',
      placement: 'bottom'
    },
    {
      element: '#activity_view',
      title: 'Activity View',
      content:
        'Access the activity view from the operators menu. This view gives you an overview of your current jobs.',
      orphan: true
    }
  ]);

  // continue where we left off according to the database if the local storage is empty and start the tour
  if (!localStorage.getItem('tour_current_step')) {
    tour.setCurrentStep(featureVersion - 1);
  }
  tour.init();
  tour.start(true);
}
