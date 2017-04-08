function setup_admin_user() {
    $('#users').DataTable( {
        "order": [[0, 'asc']]
    } );

    $('#users').on('change', 'input[name="role"]:radio', function() {
        var username = $(this).parents('tr').find('.name').text();
        var role = $(this).attr('id');
        role = $('label[for="' + role + '"]').text();
        if (confirm("Are you sure to put " + username + " into role: " + $.trim(role) + "?")) {
            $(this).parent('form').submit();
        } else {
            $(this).parent('form').find('input[class="default"]').first().prop('checked', 'checked');
        }
    });

}
