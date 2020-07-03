function setup_admin_user() {
    $('#users').DataTable({order: [[0, 'asc']]});

    $('#users').on('change', 'input[name="role"]:radio', function() {
        var username = $(this).parents('tr').find('.name').text();
        var role = $(this).attr('id');
        role = $('label[for="' + role + '"]').text();

        function findDefault(form) {
            return form.find('input[class="default"]').first();
        }

        function rollback(form) {
            findDefault(form).prop('checked', 'checked');
        }

        var form = $(this).parent('form');
        if (!confirm("Are you sure to put " + username + " into role: " + $.trim(role) + "?")) {
            rollback(form);
            return;
        }

        var data = form.serializeArray();
        var newRole = data[1].value;

        $.ajax({
            type: 'POST',
            url: form.attr('action'),
            data: jQuery.param(data),
            success: function(data) {
                findDefault(form).removeClass('default');
                form.find('input[value="' + newRole + '"]').addClass('default');
            },
            error: function(err) {
                rollback(form);
                addFlash('danger', 'An error occurred when changing the user role');
            }
        });
    });

    $('#editModal').on('shown.bs.modal', function () {
        $('#usernameFormInput').trigger('focus');
    });

    $('.edit-modal-form-input').change(validateForm);
    $('.edit-modal-form-input').keyup(validateForm);
}

function openNewUser(){
    document.selected_user_id = undefined;

    $('#usernameFormInput').val("");
    $('#emailFormInput').val("");
    $('#nameFormInput').val("");
    $('#nickFormInput').val("");
    $('#roleFormInput').val("user");

    $('#editModalForm').attr('action', '/admin/users');

    validateForm();
}

function openEditUser(id){
    document.selected_user_id = id;

    var columns = $("#user_"+id).children();
    $('#usernameFormInput').val(columns[0].textContent);
    $('#emailFormInput').val(columns[1].textContent);
    $('#nameFormInput').val(columns[2].textContent);
    $('#nickFormInput').val(columns[3].textContent);

    ["user", "operator", "admin"].some(function(role){
        if ($("#" + id + "_" + role).is(':checked')){
            $('#roleFormInput').val(role);
            return true;
        }
    });

    $('#editModalForm').attr('action', '/admin/users/' + id);

    validateForm();
}

function validateForm(){
    var isValid = true;

    $('.edit-modal-form-input').each(function(k, item){
        isValid = isValid & item.checkValidity();
        return isValid;
    });

    $("#editModalFormSaveButton").prop('disabled', !isValid);

    return isValid;
}

function onSaveUser(){
    if (!validateForm())
        return;

    $("#editModalForm").submit();
}
