function displayElements(elements, displayValue) {
  elements.forEach(element => (element.style.display = displayValue));
}

function showCommentEditor(form) {
  displayElements([form.text, form.applyChanges, form.discardChanges], 'inline');
  displayElements([form.editComment, form.removeComment, form.querySelector('.markdown')], 'none');
}

function hideCommentEditor(form) {
  displayElements([form.text, form.applyChanges, form.discardChanges], 'none');
  displayElements([form.editComment, form.removeComment, form.querySelector('.markdown')], 'block');
}

function renderDate(date) {
  const abbr = $('<abbr></abbr>');
  abbr.text(timeago.format(date));
  abbr.prop('title', date);
  timeago.render(abbr.get());
  return abbr[0];
}

function renderCommentHeading(comment, commentId) {
  const heading = document.createElement('h4');
  heading.className = 'media-heading';
  const abbrLink = document.createElement('a');
  abbrLink.href = '#comment-' + commentId;
  abbrLink.className = 'comment-anchor';
  abbrLink.appendChild(renderDate(comment.created));
  heading.append(comment.userName, ' wrote ', abbrLink);
  if (comment.updated !== comment.created) {
    heading.append(' (last edited ', renderDate(comment.updated), ')');
  }
  return heading;
}

function updateNumerOfComments() {
  const commentsLink = document.querySelector('a[href="#comments"]');
  if (commentsLink) {
    const linkText = 'Comments (' + document.getElementsByClassName('comment-row').length + ')';
    commentsLink.innerHTML = linkText;
  }
}

function deleteComment(deleteButton) {
  const author = deleteButton.dataset.author;
  if (!window.confirm('Do you really want to delete the comment written by ' + author + '?')) {
    return;
  }
  fetchWithCSRF(deleteButton.dataset.deleteUrl, {method: 'DELETE'})
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
      if (!response.ok) throw `Server returned ${response.status}: ${response.statusText}\n${json.error || ''}`;
      if (json.error) throw json.error;
      $(deleteButton).parents('.comment-row, .pinned-comment-row').remove();
      updateNumerOfComments();
    })
    .catch(error => {
      window.alert(`The comment couldn't be deleted: ${error}`);
    });
}

function updateComment(form) {
  const textElement = form.text;
  const text = textElement.value;
  if (!text.length) {
    return window.alert("The comment text mustn't be empty.");
  }
  const url = form.dataset.putUrl;
  const headingElement = form.querySelector('h4');
  const markdownElement = form.querySelector('.markdown');
  const markdown = markdownElement.innerHTML;
  displayElements([textElement, form.applyChanges, form.discardChanges], 'none');
  markdownElement.style.display = '';
  markdownElement.innerHTML = '<em>Loading…</em>';
  fetchWithCSRF(url, {method: 'PUT', body: new FormData(form)})
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
      // get rendered markdown
      fetch(url)
        .then(response => {
          if (!response.ok) throw `Server returned ${response.status}: ${response.statusText}`;
          return response.json();
        })
        .then(comment => {
          const commentId = headingElement.querySelector('.comment-anchor').href.split('#comment-')[1];
          headingElement.replaceWith(renderCommentHeading(comment, commentId));
          textElement.value = comment.text;
          markdownElement.innerHTML = comment.renderedMarkdown;
          hideCommentEditor(form);
        })
        .catch(error => {
          console.error(error);
          location.reload();
        });
    })
    .catch(error => {
      window.alert(`The comment couldn't be updated : ${error}`);
    });
}

function addComment(form, insertAtBottom) {
  const textElement = form.text;
  const text = textElement.value;
  if (!text.length) {
    return window.alert("The comment text mustn't be empty.");
  }
  const url = form.action;
  fetch(url, {method: 'POST', body: new FormData(form)})
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
      const commentId = json.id;
      console.log(`Created comment #${commentId}`);
      // get rendered markdown
      fetch(`${url}/${commentId}`)
        .then(response => {
          if (!response.ok) throw `Server returned ${response.status}: ${response.statusText}`;
          return response.json();
        })
        .then(comment => {
          const templateElement = document.getElementById('comment-row-template');
          const commentRow = $(templateElement.innerHTML.replace(/@comment_id@/g, commentId))[0];
          commentRow.querySelector('[name="text"]').value = comment.text;
          commentRow.querySelector('h4').replaceWith(renderCommentHeading(comment, commentId));
          commentRow.querySelector('.markdown').innerHTML = comment.renderedMarkdown;
          let nextElement;
          if (!insertAtBottom) {
            nextElement = document.querySelectorAll('.comment-row')[0];
          }
          if (!nextElement) {
            nextElement = templateElement;
          }
          nextElement.parentNode.insertBefore(commentRow, nextElement);
          $('html, body').animate({scrollTop: commentRow.offsetTop}, 1000);
          textElement.value = '';
          updateNumerOfComments();
        })
        .catch(error => {
          console.error(error);
          location.reload();
        });
    })
    .catch(error => {
      window.alert(`The comment couldn't be added: ${error}`);
    });
}

function insertTemplate(button) {
  const textarea = document.getElementById('text');
  const template = button.dataset.template;
  textarea.value += textarea.value ? '\n' + template : template;
}

function getUrlWithoutHash(urlStr) {
  const url = new URL(urlStr, window.location.href);
  url.hash = '';
  return url.toString();
}

let lastLoadedUrl = getUrlWithoutHash(window.location.href);

document.addEventListener('click', event => {
  const link = event.target.closest('#comment-area .comments-pagination a');
  if (!link) return;
  event.preventDefault();

  const urlStr = link.href;
  if (!urlStr) return;

  loadComments(urlStr, true);
});

function loadComments(urlStr, pushState) {
  const wrapper = document.getElementById('comment-area');
  if (!wrapper) return;

  const url = new URL(urlStr, window.location.href);
  // Transform the regular overview URL into the AJAX endpoint URL
  url.pathname = url.pathname.replace(/\/?$/, '/comments_ajax');

  fetch(url.toString(), {
    headers: {
      Accept: 'text/html'
    }
  })
    .then(response => {
      if (!response.ok) throw new Error(`Server returned ${response.status}: ${response.statusText}`);
      return response.text();
    })
    .then(html => {
      wrapper.innerHTML = html;
      lastLoadedUrl = getUrlWithoutHash(urlStr);
      if (pushState) {
        history.pushState({commentsUrl: urlStr}, '', urlStr);
      }
      if (typeof updateTimeago === 'function') {
        updateTimeago();
      }
      // If the URL has a hash (e.g. #comment-123), scroll to it after AJAX loads
      if (window.location.hash) {
        // Try/catch in case the hash is an invalid CSS selector
        try {
          const target = document.querySelector(window.location.hash);
          if (target) {
            target.scrollIntoView();
          }
        } catch (e) {
          // ignore
        }
      }
    })
    .catch(error => {
      addFlash('danger', `Failed to load comments: ${error.message || error}`);
    });
}

// A boolean to distinguish actual popstate events (user navigating history)
// from the initial popstate event that some browsers (like older Safari/Chrome)
// fire on page load.
let popstateActive = false;

// Load comments automatically when the DOM is ready
document.addEventListener('DOMContentLoaded', () => {
  const wrapper = document.getElementById('comment-area');
  if (wrapper) {
    loadComments(window.location.href, false);
  }
});

// We use setTimeout to defer setting popstateActive to true until after
// the current execution queue is empty, effectively waiting until any
// auto-triggered popstate event from page load has already fired.
window.addEventListener('load', () => {
  setTimeout(() => {
    popstateActive = true;
  }, 0);
});

// Handle browser back/forward navigation within the comment pagination.
window.addEventListener('popstate', event => {
  if (!popstateActive) return;
  const wrapper = document.getElementById('comment-area');
  if (!wrapper) return;

  const targetUrl = (event.state && event.state.commentsUrl) || window.location.href;
  if (getUrlWithoutHash(targetUrl) === lastLoadedUrl) return;

  loadComments(targetUrl, false);
});
