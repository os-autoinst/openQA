function createGroup(form) {
    var editorForm = $(form);

    $('#new_group_error').addClass('hidden');

    if(!$('#new_group_name').val().length) {
        $('#new_group_name_group').addClass('has-error');
        $('#new_group_name_group .help-block').removeClass('hidden');
        return false;
    }

    $('#new_group_creating').removeClass('hidden');
    $('#new_group_name_group').removeClass('has-error');
    $('#new_group_name_group .help-block').addClass('hidden');

    var editorForm = $(form);
    $.ajax({
        url: editorForm.data('post-url'),
        method: 'POST',
        data: editorForm.serialize(),
        success: function(response) {
            window.location.pathname = editorForm.data('redir-url') + response.id;
        },
        error: function(xhr, ajaxOptions, thrownError) {
            $('#new_group_creating').addClass('hidden');
            $('#new_group_error').removeClass('hidden');
            $('#new_group_error_message').text(thrownError);
        }
    });

    return false;
}
