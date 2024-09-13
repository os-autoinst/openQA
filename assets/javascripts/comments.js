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
  abbr.text($.timeago(date));
  abbr.prop('title', date);
  abbr.timeago();
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
      if (!response.ok) throw `Server returned ${response.status}: ${response.statusText}`;
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
      if (!response.ok) throw `Server returned ${response.status}: ${response.statusText}`;
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
      return response.json();
    })
    .then(data => {
      if (data.error) throw data.error;
      const commentId = data.id;
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
