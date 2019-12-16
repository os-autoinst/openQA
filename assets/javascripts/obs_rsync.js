function handleObsRsyncAjaxError(xhr, ajaxOptions, thrownError) {
    var message = xhr.responseJSON.error;
    if (!message) {
        message = 'no message';
    }
    addFlash('danger', 'Error: ' + message);
    $(controlToShow).show();
}

function fetchValue(url, element, controlToShow) {
    $.ajax({
        url: url,
        method: 'GET',
        success: function(response) {   
            element.innerText = response.message;
            if (controlToShow) {
                $(controlToShow).show();
            }
        },
        error: handleObsRsyncAjaxError,
    });
}

function postAndRedrawElement(btn, id, delay, confirm_message){
    if (confirm_message && !confirm(confirm_message)) {
        return
    }
    var post_url = $(btn).attr("post_url");
    var get_url = $(btn).attr("get_url");
    $(btn).hide();
    $.ajax({
        url: post_url,
        method: 'POST',
        dataType: 'json',
        success: function(data) {
            var cell = document.getElementById(id);
            if (delay) {
                if (cell) {
                    setTimeout(function() {
                        fetchValue(get_url, cell, btn);
                     }, delay);
                }
            } else {
                fetchValue(get_url, cell);
            }
        },
        error: handleObsRsyncAjaxError,
    });
}

function postAndRedirect(btn, redir){
    var post_url = $(btn).attr("post_url");
    $.ajax({
        url: post_url,
        method: 'POST',
        dataType: 'json',
        success: function(data) {
            location.href = redir;
        },
        error: handleObsRsyncAjaxError,
    });
}
