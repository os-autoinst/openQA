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

function showXhrError(context, jqXHR, textStatus, errorThrown) {
  window.alert(context + getXhrError(jqXHR, textStatus, errorThrown));
}

function updateNumberOfComments() {
  const commentsLink = document.querySelector('a[href="#comments"]');
  if (commentsLink) {
    const linkText = 'Comments (' + document.getElementsByClassName('comment-row').length + ')';
    commentsLink.innerHTML = linkText;
  }
}

//function deleteComment(deleteButton) {
//  const author = deleteButton.dataset.author;
//  if (!window.confirm('Do you really want to delete the comment written by ' + author + '?')) {
//    return;
//  }
//  $.ajax({
//    url: deleteButton.dataset.deleteUrl,
//    method: 'DELETE',
//    success: () => {
//      $(deleteButton).parents('.comment-row, .pinned-comment-row').remove();
//      updateNumberOfComments();
//    },
//    error: showXhrError.bind(undefined, "The comment couldn't be deleted: ")
//  });
//}

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
  $.ajax({
    url: url,
    method: 'PUT',
    data: $(form).serialize(),
    success: () => {
      $.ajax({
        url: url,
        method: 'GET',
        success: response => {
          const commentId = headingElement.querySelector('.comment-anchor').href.split('#comment-')[1];
          headingElement.replaceWith(renderCommentHeading(response, commentId));
          textElement.value = response.text;
          markdownElement.innerHTML = response.renderedMarkdown;
          hideCommentEditor(form);
        },
        error: () => location.reload()
      });
    },
    error: (jqXHR, textStatus, errorThrown) => {
      textElement.value = text;
      markdownElement.innerHTML = markdown;
      showCommentEditor(form);
      window.alert("The comment couldn't be updated: " + getXhrError(jqXHR, textStatus, errorThrown));
    }
  });
}

function addComment(form, insertAtBottom) {
  const textElement = form.text;
  const text = textElement.value;
  if (!text.length) {
    return window.alert("The comment text mustn't be empty.");
  }
  const url = form.action;
  $.ajax({
    url: url,
    method: 'POST',
    data: $(form).serialize(),
    success: response => {
      const commentId = response.id;
      // get rendered markdown
      $.ajax({
        url: url + '/' + commentId,
        method: 'GET',
        success: response => {
          const templateElement = document.getElementById('comment-row-template');
          const commentRow = $(templateElement.innerHTML.replace(/@comment_id@/g, commentId))[0];
          commentRow.querySelector('[name="text"]').value = response.text;
          commentRow.querySelector('h4').replaceWith(renderCommentHeading(response, commentId));
          commentRow.querySelector('.markdown').innerHTML = response.renderedMarkdown;
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
          updateNumberOfComments();
        },
        error: () => location.reload()
      });
    },
    error: showXhrError.bind(undefined, "The comment couldn't be added: ")
  });
}

function insertTemplate(button) {
  const textarea = document.getElementById('text');
  const template = button.dataset.template;
  textarea.value += textarea.value ? '\n' + template : template;
  throw new Error("DELETION ATTEMPT");
}

function getCSRFToken() {
  const metaTag = document.querySelector('meta[name="csrf-token"]');
  return metaTag ? metaTag.getAttribute('content') : '';
}

htmx.logger = function(elt, event, data) {
    if(console) {
        console.log(event, elt, data);
    }
}

htmx.on('htmx:configRequest', function(event) {
  event.detail.headers['X-CSRF-Token'] = getCSRFToken();
});

