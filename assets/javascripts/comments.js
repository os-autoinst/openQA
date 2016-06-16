function showCommentEditor(form) {
    var jform = $(form);
    jform.find('[name="text"]').show();
    jform.find('[name="applyChanges"]').show();
    jform.find('[name="discardChanges"]').show();
    jform.find('[name="editComment"]').hide();
    jform.find('[name="markdown"]').hide();
    jform.find('[name="removeComment"]').hide();
}

function hideCommentEditor(form) {
    var jform = $(form);
    jform.find('[name="text"]').hide();
    jform.find('[name="applyChanges"]').hide();
    jform.find('[name="discardChanges"]').hide();
    jform.find('[name="editComment"]').show();
    jform.find('[name="markdown"]').show();
    jform.find('[name="removeComment"]').show();
}

function renderDate(date) {
    var abbr = $('<abbr></abbr>');
    abbr.text($.timeago(date));
    abbr.prop('title', date);
    abbr.timeago();
    return abbr;
}

function renderCommentHeading(comment) {
    var heading = $('<h4></h4>');
    heading.addClass('media-heading');
    heading.append(comment.userName, ' wrote ', renderDate(comment.created));
    if(comment.created !== comment.updated) {
        heading.append(' (last edited ', renderDate(comment.updated), ')');
    }
    return heading;
}

function renderCommentRow(comment) {
    var form = $('<form>');
    form.on('submit', function() {
        updateComment(this);
        return false;
    });
    form.on('reset', function() {
        hideCommentEditor(this);
        return true;
    });
    
    // TODO
    
    var row = $('<div>');
    
    var avatar = $('<div class="col-sm-1">', {
        'html': '<img class="media-object img-circle" src="'
            + $('#commentForm .img-circle').prop('src')
            + '" alt="profile">'
    }).appendTo(row);
    
    $('<div class="col-sm-11">')
        .append($('<div class="media-body comment-body">')
            .append($('<div class="well well-lg">')
                .append(form)
    )).appendTo(row);

    return row;
}

function deleteComment(deleteButton) {    
    var deleteButton = $(deleteButton);
    var author = deleteButton.data('author');
    var url = deleteButton.data('delete-url');
    
    if(window.confirm("Do you really want to delete the comment written by " + author + "?")) {
        $.ajax({
            url: url,
            method: 'DELETE',
            success: function() {
                deleteButton.parents('.comment-row').remove();
                $('a[href="#comments"]').html('Comments (' + $('.comment-row').length + ')');
            },
            error: function(xhr, ajaxOptions, thrownError) {
                window.alert('The comment couldn\'t be deleted: ' + thrownError);
            }
        });
    }
}

function updateComment(form) {
    var editorForm = $(form);
    var url = editorForm.data('put-url');
    var headingElement = editorForm.find('h4');
    var markdownElement = editorForm.find('[name="markdown"]');
    var textElement = editorForm.find('[name="text"]');
    var markdown = editorForm.find('[name="markdown"]').html();
    var text = textElement.val();
    if(text.length) {
        textElement.hide();
        markdownElement.show();
        markdownElement.html('<em>Loading ...</em>');
        editorForm.find('[name="applyChanges"]').hide();
        editorForm.find('[name="discardChanges"]').hide();
        $.ajax({
            url: url,
            method: 'PUT',
            data: editorForm.serialize(),
            success: function() {
                // get updated markdown
                $.ajax({
                    url: url,
                    method: 'GET',
                    success: function(response) {
                        headingElement.replaceWith(renderCommentHeading(response));
                        textElement.val(response.text);
                        markdownElement.html(response.renderedMarkdown);
                        hideCommentEditor(form);
                    },
                    error: function() {
                        location.reload();
                    }
                });
            },
            error: function(xhr, ajaxOptions, thrownError) {
                textElement.val(text);
                markdownElement.html(markdown);
                showCommentEditor(form);
                window.alert('The comment couldn\'t be updated: ' + thrownError);
            }
        });   
    } else {
        window.alert('The comment text mustn\'t be empty.');
    }
}

function addComment(form) {
    var editorForm = $(form);
    var url = form.action;
    $.ajax({
        url: url,
        method: 'POST',
        data: editorForm.serialize(),
        success: function() {
            location.reload();
        },
        error: function(xhr, ajaxOptions, thrownError) {
            window.alert('The comment couldn\'t be added: ' + thrownError);
        }
    });
    
    
}
