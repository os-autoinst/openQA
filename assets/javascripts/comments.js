function showCommentEditor(form) {
  var jform = $(form);
  jform.find('[name="text"]').show();
  jform.find('[name="applyChanges"]').show();
  jform.find('[name="discardChanges"]').show();
  jform.find('[name="editComment"]').hide();
  jform.find('.markdown').hide();
  jform.find('[name="removeComment"]').hide();
}

function hideCommentEditor(form) {
  var jform = $(form);
  jform.find('[name="text"]').hide();
  jform.find('[name="applyChanges"]').hide();
  jform.find('[name="discardChanges"]').hide();
  jform.find('[name="editComment"]').show();
  jform.find('.markdown').show();
  jform.find('[name="removeComment"]').show();
}

function renderDate(date) {
  var abbr = $('<abbr></abbr>');
  abbr.text($.timeago(date));
  abbr.prop('title', date);
  abbr.timeago();
  return abbr;
}

function renderCommentHeading(comment, commentId) {
  var heading = $('<h4></h4>');
  heading.addClass('media-heading');
  var abbr_link = $('<a></a>');
  abbr_link.prop('href', '#comment-' + commentId);
  abbr_link.prop('class', 'comment-anchor');
  abbr_link.append(renderDate(comment.created));
  heading.append(comment.userName, ' wrote ', abbr_link);
  if (comment.updated !== comment.created) {
    heading.append(' (last edited ', renderDate(comment.updated), ')');
  }
  return heading;
}

function getXhrError(xhr, thrownError) {
  try {
    return JSON.parse(xhr.responseText).error || thrownError;
  } catch {
    return thrownError;
  }
}

function deleteComment(deleteButton) {
  deleteButton = $(deleteButton);
  var author = deleteButton.data('author');
  var url = deleteButton.data('delete-url');

  if (window.confirm('Do you really want to delete the comment written by ' + author + '?')) {
    $.ajax({
      url: url,
      method: 'DELETE',
      success: function () {
        deleteButton.parents('.comment-row').remove();
        deleteButton.parents('.pinned-comment-row').remove();
        $('a[href="#comments"]').html('Comments (' + $('.comment-row').length + ')');
      },
      error: function (xhr, ajaxOptions, thrownError) {
        window.alert("The comment couldn't be deleted: " + getXhrError(xhr, thrownError));
      }
    });
  }
}

function updateComment(form) {
  var editorForm = $(form);
  var url = editorForm.data('put-url');
  var headingElement = editorForm.find('h4');
  var markdownElement = editorForm.find('.markdown');
  var textElement = editorForm.find('[name="text"]');
  var markdown = markdownElement.html();
  var text = textElement.val();
  if (text.length) {
    textElement.hide();
    markdownElement.show();
    markdownElement.html('<em>Loading…</em>');
    editorForm.find('[name="applyChanges"]').hide();
    editorForm.find('[name="discardChanges"]').hide();
    $.ajax({
      url: url,
      method: 'PUT',
      data: editorForm.serialize(),
      success: function () {
        // get updated markdown
        $.ajax({
          url: url,
          method: 'GET',
          success: function (response) {
            var commentId = headingElement.find('[class="comment-anchor"]')[0].href.split('#comment-')[1];
            headingElement.replaceWith(renderCommentHeading(response, commentId));
            textElement.val(response.text);
            markdownElement.html(response.renderedMarkdown);
            hideCommentEditor(form);
          },
          error: function () {
            location.reload();
          }
        });
      },
      error: function (xhr, ajaxOptions, thrownError) {
        textElement.val(text);
        markdownElement.html(markdown);
        showCommentEditor(form);
        window.alert("The comment couldn't be updated: " + getXhrError(xhr, thrownError));
      }
    });
  } else {
    window.alert("The comment text mustn't be empty.");
  }
}

function addComment(form, insertAtBottom) {
  var editorForm = $(form);
  var textElement = editorForm.find('[name="text"]');
  var text = textElement.val();

  if (text.length) {
    var url = form.action;
    $.ajax({
      url: url,
      method: 'POST',
      data: editorForm.serialize(),
      success: function (response) {
        var commentId = response.id;
        // get rendered markdown
        $.ajax({
          url: url + '/' + commentId,
          method: 'GET',
          success: function (response) {
            var commentRow = $(
              $('#comment-row-template')
                .html()
                .replace(/@comment_id@/g, commentId)
            );
            commentRow.find('h4').replaceWith(renderCommentHeading(response, commentId));
            commentRow.find('[name="text"]').val(response.text);
            commentRow.find('.markdown').html(response.renderedMarkdown);
            var nextElement;
            if (!insertAtBottom) {
              nextElement = $('.comment-row').first();
            }
            if (!nextElement || !nextElement.length) {
              nextElement = $('#comment-row-template');
            }
            commentRow.insertBefore(nextElement);
            $('html, body').animate({scrollTop: commentRow.offset().top}, 1000);
            textElement.val('');
            $('a[href="#comments"]').html('Comments (' + $('.comment-row').length + ')');
          },
          error: function () {
            location.reload();
          }
        });
      },
      error: function (xhr, ajaxOptions, thrownError) {
        window.alert("The comment couldn't be added: " + getXhrError(xhr, thrownError));
      }
    });
  } else {
    window.alert("The comment text mustn't be empty.");
  }
}

function insertTemplate(button) {
  const textarea = document.getElementById('text');
  const template = button.dataset.template;
  textarea.value += textarea.value ? '\n' + template : template;
}
