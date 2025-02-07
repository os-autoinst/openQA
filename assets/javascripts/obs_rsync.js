function fetchValue(url, element, controlToShow) {
  fetch(url)
    .then(response => {
      if (!response.ok) throw `Server returned ${response.status}: ${response.statusText}`;
      return response.json();
    })
    .then(response => {
      if (response.error) throw response.error;
      element.innerText = response?.message ?? '';
      if (controlToShow) {
        $(controlToShow).show();
      }
    })
    .catch(error => {
      console.error(error);
      addFlash('danger', `Error: ${error}`);
      if (controlToShow) {
        $(controlToShow).show();
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
  fetchWithCSRF(btn.dataset.posturl, {method: 'POST'})
    .then(response => {
      return response
        .json()
        .then(json => {
          // Attach the parsed JSON to the response object for further use
          return {response, json};
        })
        .catch(() => {
          // If parsing fails, handle it as a non-JSON response
          throw `Server returned ${response.status}: ${response.statusText}`;
        });
    })
    .then(({response, json}) => {
      if (!response.ok || json.error)
        throw `Server returned ${response.status}: ${response.statusText}\n${json.error || ''}`;
      if (!delay || window.skipObsRsyncDelay) {
        fetchValue(getUrl, cell);
        return;
      }
      setTimeout(() => {
        fetchValue(getUrl, cell, btn);
      }, delay);
    })
    .catch(error => {
      console.error(error);
      addFlash('danger', `Error: ${error}`);
    });
}

function postAndRedirect(btn, redir = '') {
  fetchWithCSRF(btn.dataset.posturl, {method: 'POST'})
    .then(response => {
      return response
        .json()
        .then(json => {
          // Attach the parsed JSON to the response object for further use
          return {response, json};
        })
        .catch(() => {
          // If parsing fails, handle it as a non-JSON response
          throw `Server returned ${response.status}: ${response.statusText}`;
        });
    })
    .then(({response, json}) => {
      if (!response.ok || json.error)
        throw `Server returned ${response.status}: ${response.statusText}\n${json.error || ''}`;
      if (redir) {
        location.href = redir;
      }
    })
    .catch(error => {
      console.error(error);
      addFlash('danger', `Error: ${error}`);
    });
}
