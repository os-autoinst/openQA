// Example

function startTour() {
    //Create a new tour
    var tour = new Tour({
    storage : false //Disabled for test purposes
  });

//Add your steps
    tour.addSteps([
        {
          element: ".jumbotron",
          title: "Welcome to my example tour!",
          content: "We're going to make this quick and useful.",
          placement: "bottom"
        },
        {
          element: ".navbar",
          title: "Navigation bar",
          content: "Use me to navigate through openQA!",
          placement: "bottom",
          backdrop: true
        },
        {
          element: "#filter-panel",
          title: "It's me the filter panel!",
          content: "I'm able to filter everything!",
          placement: "top",
          backdrop: true
        },
      ]);

    // Initialize the tour
    tour.init();

    // Start the tour
    tour.start();
};
