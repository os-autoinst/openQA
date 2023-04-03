function handleObsRsyncAjaxError(xhr, ajaxOptions, thrownError) {
  const message = xhr.responseJSON?.error ?? thrownError ?? 'no message';
  addFlash('danger', `Error: ${message}`);
}

function fetchValue(url, element, controlToShow) {
  $.ajax({
    url,
    method: 'GET',
    success: (response) => {
      element.innerText = response?.message ?? '';
      if (controlToShow) {
        $(controlToShow).show();
      }
    },
    error: (xhr, ajaxOptions, thrownError) => {
      handleObsRsyncAjaxError(xhr, ajaxOptions, thrownError);
      if (controlToShow) {
        $(controlToShow).show();
      }
    }
  });
}

function postAndRedrawElement(btn, id, delay = 0, confirmMessage = '') {
  if (confirmMessage && !confirm(confirmMessage)) {
    return;
  }
  $(btn).hide();
  const cell = document.getElementById(id);
  if (!cell) {
    addFlash('danger', 'Internal error: Unable to find related cell.');
    return;
  }
  const getUrl = btn.dataset.geturl;
  if (!getUrl) {
    addFlash('danger', 'Internal error: Unable to find GET URL.');
    return;
  }
  $.ajax({
    url: btn.dataset.posturl,
    method: 'POST',
    dataType: 'json',
    success: (data) => {
      if (!delay || window.skipObsRsyncDelay) {
        fetchValue(getUrl, cell);
        return;
      }
      setTimeout(() => {
        fetchValue(getUrl, cell, btn);
      }, delay);
    },
    error: handleObsRsyncAjaxError
  });
}

function postAndRedirect(btn, redir = '') {
  $.ajax({
    url: btn.dataset.posturl,
    method: 'POST',
    dataType: 'json',
    success: (data) => {
      if (redir) {
        location.href = redir;
      }
    },
    error: handleObsRsyncAjaxError
  });
}
