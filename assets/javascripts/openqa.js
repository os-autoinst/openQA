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
    // workaround for popover with hover on text for firefox
    $('[data-toggle="popover"]').on('click', function (e) {
        e.target.closest('a').focus();
    });

    //$('[data-submenu]').submenupicker();

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

function toggleChildGroups(link) {
    var buildRow = $(link).parents('.build-row');
    buildRow.toggleClass('children-collapsed');
    buildRow.toggleClass('children-expanded');
    return false;
}

function parseQueryParams() {
    var params = {};
    $.each(window.location.search.substr(1).split('&'), function(index, param) {
        var equationSignIndex = param.indexOf('=');
        if (equationSignIndex < 0) {
            var key = decodeURIComponent(param);
            var value = undefined;
        } else {
            var key = decodeURIComponent(param.substr(0, equationSignIndex));
            var value = decodeURIComponent(param.substr(equationSignIndex + 1));
        }
        if (Array.isArray(params[key])) {
            params[key].push(value);
        } else {
            params[key] = [value];
        }
    });
    return params;
}

function updateQueryParams(params) {
    if (!history.replaceState) {
        return; // skip if not supported
    }
    var search = [];
    $.each(params, function(key, values) {
        $.each(values, function(index, value) {
            if (value === undefined) {
                search.push(encodeURIComponent(key));
            } else {
                search.push(encodeURIComponent(key) + '=' + encodeURIComponent(value));
            }
        });
    });
    history.replaceState({} , document.title, window.location.pathname + '?' + search.join('&'));
}

function renderDataSize(sizeInByte) {
    var unitFactor = 1073741824; // one GiB
    var sizeWithUnit = 0;
    $.each([' GiB', ' MiB', ' KiB', ' byte'], function(index, unit) {
        if (!unitFactor || sizeInByte >= unitFactor) {
            sizeWithUnit = (Math.round(sizeInByte / unitFactor * 100) / 100) + unit;
            return false;
        }
        unitFactor >>= 10;
    });
    return sizeWithUnit;
}
