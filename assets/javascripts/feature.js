function newFeature() {

    var currentFeature;
    checkVersion();

    //Create variable for each tour
    var example = new Tour({
        //Enable to save progress local, necessary for multipage traversal
        storage: window.localStorage,
        template: changeTemplate(),
        onShown: function(){return dontShow(), currentFeature = 2; quitTour(currentFeature)}
    });

    //Add steps to the tour
    example.addSteps([
        {
          element: ".jumbotron",
          title: "Interested in new features?",
          content: "Just click next to see what's new in openQA",
          placement: "bottom",
          backdrop: true,
          onNext: function(){return ($('.panel-heading').click())}
        },
        {
          element: "#filter-fullscreen",
          title: "Full screen mode",
          content: "Check out the new full screen view option",
          placement: "top",
          backdrop: false,
          onNext: function(){document.location.href = '/tests/'},
        },
        {
          element: "#scheduled_wrapper",
          title: "Multipage",
          content: "Example about traversing across pages",
          placement: "bottom",
          onPrev: function(){document.location.href = '/'},
        }
    ]);

    //Parse html code as string to change the default layout of bootstrap tour
    function changeTemplate() {
        return ("<div class='popover tour'>"+
                "<div class='arrow'></div>"+
                "<h3 class='popover-title'></h3>"+
                "<div class='popover-content'></div>"+
                "<div class='popover-navigation'>"+
                "<div class='checkbox'><label><input type='checkbox' id='dont-notify'>Don't notify me anymore</label></div>"+
                "<button class='btn btn-default' data-role='prev' id='prev'>« Prev</button>"+
                "<span data-role='separator'>|</span>"+
                "<button class='btn btn-default' data-role='next'id='next'>Next »</button>"+
                "<button class='btn btn-default' data-role='end' id='end'>Quit</button>"+
                "</div>"+
                "</div>")
    };

    function quitTour(currentFeature){
        $('#end').on('click', function(){return endTour(currentFeature)});
    };

    //Check database for allready shown features
    function checkVersion() {
        $.ajax({
            dataType: "json",
            url: '/api/v1/feature',
            method: 'GET',
            success: function(data){
                getResult(data);
            }
        });
    };

    //Get results from database query and start tour depending on result
    function getResult(data) {
        var version = data.version;
        if ((2 > version) && (version != 0)) {
            //Initialize the tour
            example.init();
            //Start the tour
            example.start();
        };
    };

    //Return progress (already seen features) to database
    function endTour(currentFeature) {
        $.ajax({
            url: '/api/v1/feature',
            method: 'POST',
            data:
                {
                  'version' : currentFeature,
                }
        });
    };

    //Give user the opportunity to disable feature notfications
    function dontShow() {
        $('#dont-notify').change(function() {
            var checked = $('#dont-notify').is(':checked');
            if (checked) {
                $("#end").text('Confirm');
                $("#end").attr('id', 'confirm');
            }
            else {
                $("#confirm").attr('id', 'end');
                $("#end").text('Quit');
            }

        $('#confirm').on('click', function(){
          currentFeature = 0;
          return endTour(currentFeature);
        });
    })};
};
