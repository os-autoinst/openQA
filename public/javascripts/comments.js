function showCommentEditor(commentId, form) {
    form.text.style.display = "block";
    form.editComment.style.display = "none";
    document.getElementById("removeComment_" + commentId).style.display = "none";
    form.applyChanges.style.display = "inline";
    form.discardChanges.style.display = "inline";
    document.getElementById("commentMd_" + commentId).style.display = "none";
}

function hideCommentEditor(commentId, form) {
    form.text.style.display = "none";
    form.editComment.style.display = "inline";
    document.getElementById("removeComment_" + commentId).style.display = "inline";
    form.applyChanges.style.display = "none";
    form.discardChanges.style.display = "none";
    document.getElementById("commentMd_" + commentId).style.display = "block";
}

function confirmCommentRemoval(author) {
    return window.confirm("Do you really want to delete the comment written by " + author + "?");
}
