function showCommentEditor(commentId, form) {
    var jform = $(form);
    jform.find('[name="text"]').show();
    jform.find('[name="applyChanges"]').show();
    jform.find('[name="discardChanges"]').show();
    jform.find('[name="editComment"]').hide();
    jform.find('#commentMd_' + commentId).hide();
    jform.find('#removeComment_' + commentId).hide();
}

function hideCommentEditor(commentId, form) {
    var jform = $(form);
    jform.find('[name="text"]').hide();
    jform.find('[name="applyChanges"]').hide();
    jform.find('[name="discardChanges"]').hide();
    jform.find('[name="editComment"]').show();
    jform.find('#commentMd_' + commentId).show();
    jform.find('#removeComment_' + commentId).show();
}

function confirmCommentRemoval(author) {
    return window.confirm("Do you really want to delete the comment written by " + author + "?");
}
