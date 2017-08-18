function setupGroupOverview() {
    $('.timeago').timeago();

    setupFilterForm();
    $('#filter-show-comments').prop('checked', true);
    $('#filter-latest-comment').prop('checked', false);
    $('#filter-fullscreen').prop('checked', false);
    $('#filter-latest-comment').on('change', function() {
        var checked = $('#filter-latest-comment').prop('checked');
        var showCommentsElement = $('#filter-show-comments');
        if (checked) {
            showCommentsElement.prop('checked', true);
        }
        showCommentsElement.prop('disabled', checked);
    });

    parseFilterArguments(function(key, val) {
        if (key === 'show_comments') {
            $('#filter-show-comments').prop('checked', val !== '0');
            return 'show comments';
        } else if (key === 'latest_comment') {
            $('#filter-latest-comment').prop('checked', val !== '0');
            $('#filter-only-tagged').trigger('change');
            return 'only tagged';
        } else if (key === 'fullscreen') {
          $('#filter-fullscreen').prop('checked', val !== '0');
          return 'fullscreen';
        }
    });
}

function hideNavbar() {

    var mouseY = 0;
    var navbarHeight = $(".navbar").outerHeight();
    navbarHeight -= 30;

    if ($('#filter-fullscreen').is(':checked')) {
        $("#content").attr('id', 'content_fullscreen');
        $(".navbar").addClass('hidden');
        $(".footer").addClass('hidden');
        $("#group_description").addClass('hidden');
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
