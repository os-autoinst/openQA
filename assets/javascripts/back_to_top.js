function backToTop() {
    $(document).ready(function() {
        $(window).scroll(function() {
            // Increase the value to not show the button on shorter pages
            if ($(this).scrollTop() > 50) {
                $('#back-to-top').fadeIn();
            } else {
                $('#back-to-top').fadeOut();
            }
        });
        $('#back-to-top').click(function() {
            $('#back-to-top').tooltip('hide');
            $('body, html').animate({ scrollTop: 0 }, 800);
            return false;
        });
        $('#back-to-top').tooltip('show');
    });
}