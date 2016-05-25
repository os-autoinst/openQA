function showCommentEditor(commentId, form) {
    form.text.style.display = "block";
    form.editComment.style.display = "none";
    var removeCommentElement = document.getElementById("removeComment_" + commentId);
    if(removeCommentElement) {
        removeCommentElement.style.display = "none";
    }
    form.applyChanges.style.display = "inline";
    form.discardChanges.style.display = "inline";
    document.getElementById("commentMd_" + commentId).style.display = "none";
}

function hideCommentEditor(commentId, form) {
    form.text.style.display = "none";
    form.editComment.style.display = "inline";
    var removeCommentElement = document.getElementById("removeComment_" + commentId);
    if(removeCommentElement) {
        removeCommentElement.style.display = "inline";
    }
    form.applyChanges.style.display = "none";
    form.discardChanges.style.display = "none";
    document.getElementById("commentMd_" + commentId).style.display = "block";
}

function confirmCommentRemoval(author) {
    return window.confirm("Do you really want to delete the comment written by " + author + "?");
}
