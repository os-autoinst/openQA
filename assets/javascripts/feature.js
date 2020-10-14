function newFeature(featureVersion) {
    const latestFeature = 4;
    var currentFeature;

    //Create variable for each tour
    //For instructions about creating a tour checkout http://bootstraptour.com/api/
    var tour01 = new Tour({
        //Enable to save progress local, necessary for multipage traversal
        storage: window.localStorage,
        template: changeTemplate(),
        onShown: function() {
            return dontShow(), currentFeature = latestFeature, quitTour(currentFeature);
        },
    });

    //Add steps to the tour
    tour01.addSteps([{
        element: "#all_tests",
        title: "All tests area",
        content: "In this area all tests are provided and grouped by the current state. You can see which jobs are running, scheduled or finished.",
        placement: "bottom",
        backdrop: false,
    }, {
        element: "#job_groups",
        title: "Job group menu",
        content: "Access the job group overview pages from here. Besides test results, a description and commenting area are provided.",
        placement: "bottom",
        backdrop: false,
    }, {
        element: "#user-action",
        title: "User menu",
        content: "Access your user menu from here.",
        placement: "bottom",
    }, {
        element: "#activity_view",
        title: "Activity View",
        content: "Access the activity view from here. This view gives you an overview of your current jobs.",
        placement: "right",
        orphan: true,
        onShown: function() { $('#user-action .dropdown-toggle').click(); },
        onHidden: function() { $('#user-action .dropdown-toggle').click(); },
    }]);

    initTour(featureVersion);

    //Parse html code as string to change the default layout of bootstrap tour
    function changeTemplate() {
        return ("<div class='popover tour'>" +
            "<div class='arrow'></div>" +
            "<h3 class='popover-header'></h3>" +
            "<div class='popover-body'></div>" +
            "<div class='popover-navigation'>" +
            "<div class='checkbox'><label><input type='checkbox' id='dont-notify'>Don't notify me anymore (permanent)</label></div>" +
            "<button class='btn btn-default' data-role='prev' id='prev'>« Prev</button>" +
            "<button class='btn btn-default' data-role='next'id='next'>Next »</button>" +
            "<button class='btn btn-default' data-role='end' id='end'>Quit</button>" +
            "</div>" +
            "</div>");
    }

    function quitTour(currentFeature) {
        $('#end').on('click', function() {
            return endTour(currentFeature);
        });
    }

    function initTour(featureVersion) {
        if (latestFeature > featureVersion && featureVersion > 0) {
            //Initialize the tour
            tour01.init(true);
            tour01._current = null;
            //Start the tour
            tour01.start();
        }
    }

    //Return progress (seen features) to database
    function endTour(currentFeature) {
        $.ajax({
            url: '/api/v1/feature',
            method: 'POST',
            data: { version: currentFeature },
        });
    }

    //Give user the opportunity to disable feature notfications
    function dontShow() {
        $('#dont-notify').change(function() {
            var checked = $('#dont-notify').is(':checked');
            if (checked) {
                $("#end").text('Confirm');
                $("#end").attr('id', 'confirm');
            } else {
                $("#confirm").attr('id', 'end');
                $("#end").text('Quit');
            }
            $('#confirm').on('click', function() {
                currentFeature = 0;
                return endTour(currentFeature);
            });
        });
    }
}