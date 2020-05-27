function setup_admin_user() {
    $('#users').DataTable( {
        "order": [[0, 'asc']]
    } );

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

        if (confirm("Are you sure to put " + username + " into role: " + $.trim(role) + "?")) {
            var data = form.serializeArray();
            var newRole = data[1].value;

            $.ajax({
                type: 'POST',
                url: form.attr('action'),
                data: jQuery.param(data),
                success: function(data){
                    findDefault(form).removeClass('default');
                    form.find('input[value="' + newRole + '"]').addClass('default');
                },
                error: function(err){
                    rollback(form);
                    addFlash('danger', 'An error occurred when changing the user role');
                }
            });
        } else
            rollback(form);
    });
}
