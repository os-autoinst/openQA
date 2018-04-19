function hideNavbar(fullscreen) {
    // do nothing if not in full screen mode
    if (!$('#filter-fullscreen').is(':checked') && fullscreen !== 1) {
        return;
    }

    // change ID of main container (to change applied CSS rules)
    $("#content").attr('id', 'content_fullscreen');

    // hide some elements
    $(".navbar, .footer, .jumbotron").hide();
    if (fullscreen === 1) {
        $("#group_description").hide();
    }

    // toggle navbar visibility
    var navbar = $(".navbar");
    var navbarHeight = navbar.outerHeight();
    document.addEventListener('mousemove', function(e) {
        var mouseY = e.clientY || e.pageY;
        if (mouseY <= navbarHeight || navbar.find("[aria-expanded='true']").length != 0) {
            navbar.show();
        }
        else if (mouseY > navbarHeight && !$("li").hasClass('dropdown open')) {
            navbar.hide();
        }
    }, false);
};

function autoRefresh(fullscreen, interval) {
    if (fullscreen == 1) {
        $($(document).ready(function() {
            setInterval(function() {
                $("#build-results").load(location.href + " #build-results");
                $("#comments-preview").load(location.href + " #comments-preview");
            }, interval*1000);
        }));
    };
};
