function hideNavbar(fullscreen) {

    var mouseY = 0;
    var navbarHeight = $(".navbar").outerHeight();
    navbarHeight -= 30;

    if (($('#filter-fullscreen').is(':checked')) || (fullscreen == 1)) {
        $("#content").attr('id', 'content_fullscreen');
        $(".navbar").hide();
        $(".footer").hide();
        $(".jumbotron").hide();
        if (fullscreen == 1) {
            $("#group_description").hide();
        }
        document.addEventListener('mousemove', function(e){
            mouseY = e.clientY || e.pageY;
            if (mouseY < navbarHeight) {
                $(".navbar").show();
            }
            else if (mouseY > navbarHeight) {
                if (!$("li").hasClass('dropdown open')) {
                    $(".navbar").hide();
                }
            }
        }, false);
    }
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
