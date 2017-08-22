function hideNavbar(fullscreen) {

    var mouseY = 0;
    var navbarHeight = $(".navbar").outerHeight();
    navbarHeight -= 30;

    if (($('#filter-fullscreen').is(':checked')) || (fullscreen == 1)) {
        $("#content").attr('id', 'content_fullscreen');
        $(".navbar").addClass('hidden');
        $(".footer").addClass('hidden');
        $(".jumbotron").addClass('hidden');
        if (fullscreen == 1) {
            $("#group_description").addClass('hidden');
        }
        document.addEventListener('mousemove', function(e){
            mouseY = e.clientY || e.pageY;
            if (mouseY < navbarHeight) {
                $(".navbar").removeClass('hidden').addClass('show');
            }
            else if (mouseY > navbarHeight) {
                if (!$("li").hasClass('dropdown open')) {
                    $(".navbar").removeClass('show').addClass('hidden');
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
