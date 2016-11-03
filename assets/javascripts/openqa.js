function setCookie(cname, cvalue, exdays) {
    var d = new Date();
    d.setTime(d.getTime()+(exdays*24*60*60*1000));
    var expires = "expires="+d.toGMTString();
    document.cookie = cname + "=" + cvalue + "; " + expires;
}

function getCookie(cname) {
    var name = cname + "=";
    var ca = document.cookie.split(';');
    for(var i=0; i<ca.length; i++) {
        var c = ca[i].trim();
        if (c.indexOf(name)==0) return c.substring(name.length,c.length);
    }
    return false;
}

function setupForAll() {
    $('[data-toggle="tooltip"]').tooltip({html: true});
    $('[data-toggle="popover"]').popover({html: true});

    $.ajaxSetup({
        headers:
        { 'X-CSRF-TOKEN': $('meta[name="csrf-token"]').attr('content') }
    });
}

function addFlash(status, text) {
    // keep design in line with the static in layouts/info
    var flash = $('#flash-messages');
    var div = $('<div class="alert fade in"><button class="close" data-dismiss="alert">x</button></div>');
    div.append($("<span>" + text + "</span>"));
    div.addClass('alert-' + status);
    flash.append(div);
}
