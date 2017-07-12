function newFeature() {

    var version = "";
    var currentFeature = 1;

    var feature01 = new Tour({
        //Enable to save progress local
        storage: false
    });

    feature01.addSteps([
        {
          element: ".jumbotron",
          title: "Interested in new features?",
          content: "Just click next to see what's new in openQA",
          placement: "bottom",
          backdrop: false,
          template: changeTemplate(),
        },
        {
          element: "#filter-fullscreen",
          title: "Full screen mode",
          content: "Check out the new full screen view option",
          placement: "top",
          backdrop: false,
          onShown: function(){return endTour()}
        }
    ]);

    function changeTemplate() {
        return ("<div class='popover tour'>"+
                "<div class='arrow'></div>"+
                "<h3 class='popover-title'></h3>"+
                "<div class='popover-content'></div>"+
                "<div class='popover-navigation'>"+
                "<div class='checkbox'><label><input type='checkbox'>Don't show again</label></div>"+
                "<button class='btn btn-default' data-role='prev'>« Prev</button>"+
                "<span data-role='separator'>|</span>"+
                "<button class='btn btn-default' data-role='next'>Next »</button>"+
                "<button class='btn btn-default' data-role='end'>End tour</button>"+
                "</div>"+
                "</div>")
    };

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

    function getResult(data, version) {
        version = data.version;
    };

    if (currentFeature > version) {
        //Initialize the tour
        feature01.init();
        //Start the tour
        feature01.start();
    };

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
};
