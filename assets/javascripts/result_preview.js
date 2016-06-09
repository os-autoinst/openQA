function preview(a, force) {
    if ((a.length && !a.is('.current_preview')) || force) {
        // show
        $('.current_preview').removeClass('current_preview');
        a.addClass('current_preview');

        var td = a.parent();
        var a_index = td.children('.links_a').index(a);

        // a width = 64
        var as_per_row = Math.floor(td.width() / 64);
        var full_top_rows = Math.ceil((a_index+1) / as_per_row);
        var preview_offset = (as_per_row * full_top_rows) - 1;
        var as_count = td.children('.links_a').length - 1;
        if (as_count < preview_offset) {
            preview_offset = as_count;
        }

        var href = a.find('a').attr('href');
        $('#preview_container_in').load(href, function() {
            var hotlink = location.href.split('#')[0].split('?')[0] + '?' + href.replace(/\/tests\/[0-9]+\/modules\//, '');
            window.history.replaceState({}, 'preview', hotlink);
            $('#dummy_space').show();
            $('#preview_container_out').insertAfter(td.children('.links_a').eq(preview_offset));
            if ($('#preview_container_in').find('pre').length > 0 || $('#preview_container_in').find('audio').length > 0) {
                $('#preview_container_in').find('pre, div').css('width', $('.links').width());
                $('#preview_container_in').css('left', 0);
                $('#preview_container_in').addClass('nobg');
            }
            else {
                $('#preview_container_in').css('left', -($('.result').width()+$('.component').width()+2*16));
                $('#preview_container_in').removeClass('nobg');
            }
            $('#preview_container_out').css('display', 'block').css('height', $('#preview_container_in').height());
            $('body, html').stop(true, true).animate({scrollTop: a.offset().top-3, queue: false}, 250);
        });
    }
    else {
        // hide
        $('#dummy_space').hide(300);
        $('#preview_container_out').css('display', 'none');
        $('.current_preview').removeClass('current_preview');
        window.history.replaceState({}, 'testresult', location.href.split('#')[0].split('?')[0]);
    }

}

function next() {
    var a = $('.current_preview');
    if(a) {
        var table = $('.current_preview').parents('table');
        var a_index = table.find('.links_a').index(a);
        var next_a = a_index + 1;
        var b = table.find('.links_a').eq(next_a);
        if (b.length) {
            preview(b);
        }
    }
}

function prev() {
    var a = $('.current_preview');
    if(a) {
        var table = $('.current_preview').parents('table');
        var a_index = table.find('.links_a').index(a);
        var next_a = a_index - 1;
        if (next_a >= 0) {
            var b = table.find('.links_a').eq(next_a);
            if (b.length) {
                preview(b);
            }
        }
    }
}

$(window).keydown(function(e) {
    var ftn = $(':focus').prop("tagName");
    if (ftn == "INPUT" || ftn == "TEXTAREA") {
        return;
    }
    if (e.shiftKey || e.metaKey || e.ctrlKey || e.altKey) {
        return;
    }
    if (e.which == 37) { // left
        prev();
        e.preventDefault();
    }
    else if (e.which == 39) { // right
        next();
        e.preventDefault();
    }
});

$(window).resize(function() {
    if($('.current_preview')) {
        preview($('.current_preview'), true);
    }
});
