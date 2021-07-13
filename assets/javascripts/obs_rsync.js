function handleObsRsyncAjaxError(xhr, ajaxOptions, thrownError) {
  var message = xhr.responseJSON.error;
  if (!message) {
    message = thrownError ? thrownError : 'no message';
  }
  addFlash('danger', 'Error: ' + message);
}

function fetchValue(url, element, controlToShow) {
  $.ajax({
    url: url,
    method: 'GET',
    success: function (response) {
      element.innerText = response.message;
      if (controlToShow) {
        $(controlToShow).show();
      }
    },
    error: function (xhr, ajaxOptions, thrownError, controlToShow) {
      handleObsRsyncAjaxError(xhr, ajaxOptions, thrownError);
      if (controlToShow) {
        $(controlToShow).show();
      }
    }
  });
}

function postAndRedrawElement(btn, id, delay, confirmMessage) {
  if (confirmMessage && !confirm(confirmMessage)) {
    return;
  }
  $(btn).hide();
  var cell = document.getElementById(id);
  if (!cell) {
    addFlash('danger', 'Internal error: Unable to find related cell.');
    return;
  }
  $.ajax({
    url: btn.dataset.posturl,
    method: 'POST',
    dataType: 'json',
    success: function (data) {
      if (!delay || window.skipObsRsyncDelay) {
        fetchValue(btn.dataset.geturl, cell);
        return;
      }
      setTimeout(function () {
        fetchValue(btn.dataset.geturl, cell, btn);
      }, delay);
    },
    error: handleObsRsyncAjaxError
  });
}

function postAndRedirect(btn, redir) {
  $.ajax({
    url: btn.dataset.posturl,
    method: 'POST',
    dataType: 'json',
    success: function (data) {
      location.href = redir;
    },
    error: handleObsRsyncAjaxError
  });
}
