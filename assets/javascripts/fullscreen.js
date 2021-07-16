function toggleFullscreenMode(fullscreen) {
  // change ID of main container (to change applied CSS rules)
  $('#content').attr('id', fullscreen ? 'content_fullscreen' : 'content');

  // change visibility of some elements
  $('.navbar, .footer, .jumbotron, #group_description')[fullscreen ? 'hide' : 'show']();

  // toggle navbar visibility
  var navbar = $('.navbar');
  var navbarHeight = navbar.outerHeight();
  var handler = document.showNavbarIfItWouldContainMouse;
  if (!fullscreen) {
    if (handler === undefined) {
      return;
    }
    document.removeEventListener('mousemove', handler, false);
    return;
  }
  handler = document.showNavbarIfItWouldContainMouse = function (e) {
    var mouseY = e.clientY || e.pageY;
    if (mouseY <= navbarHeight || navbar.find("[aria-expanded='true']").length !== 0) {
      navbar.show();
    } else if (mouseY > navbarHeight && !$('li').hasClass('dropdown open')) {
      navbar.hide();
    }
  };
  document.addEventListener('mousemove', handler, false);
}

function autoRefresh(fullscreen, interval) {
  if (!fullscreen) {
    return;
  }
  $(
    $(document).ready(function () {
      setInterval(function () {
        $('#build-results').load(location.href + ' #build-results');
        $('#comments-preview').load(location.href + ' #comments-preview');
      }, interval * 1000);
    })
  );
}
