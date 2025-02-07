function setup_admin_user() {
  window.admin_user_table = $('#users').DataTable({
    order: [[0, 'asc']]
  });

  $('#users').on('change', 'input[name="role"]:radio', function () {
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
    if (!confirm('Are you sure to put ' + username + ' into role: ' + $.trim(role) + '?')) {
      rollback(form);
      return;
    }

    var data = new FormData(form[0]);
    var newRole = data.get('role');

    fetch(form.attr('action'), {method: 'POST', body: data, headers: {Accept: 'application/json'}, redirect: 'error'})
      .then(response => {
        return response
          .json()
          .then(json => {
            // Attach the parsed JSON to the response object for further use
            return {response, json};
          })
          .catch(() => {
            // If parsing fails, handle it as a non-JSON response
            throw `Server returned ${response.status}: ${response.statusText}`;
          });
      })
      .then(({response, json}) => {
        if (!response.ok) throw `Server returned ${response.status}: ${response.statusText}<br>${json.error || ''}`;
        if (json.error) throw json.error;
        if (json.status) addFlash('info', json.status);
        findDefault(form).removeClass('default');
        form.find('input[value="' + newRole + '"]').addClass('default');
      })
      .catch(error => {
        console.error(error);
        rollback(form);
        addFlash('danger', `An error occurred when changing the user role: ${error}`);
      });
  });

  window.deleteUser = function (id) {
    if (!confirm('Are you sure you want to delete this user?')) return;

    fetchWithCSRF(urlWithBase('/api/v1/user/' + id), {method: 'DELETE'})
      .then(response => {
        if (response.status >= 500 && response.status < 600)
          throw 'An internal server error has occurred. Maybe there are unsatisfied foreign key restrictions in the DB for this user.';
        if (!response.ok) throw `Server returned ${response.status}: ${response.statusText}`;
        return response.json();
      })
      .then(response => {
        if (response.error) throw response.error;
        addFlash('info', 'The user was deleted successfully.');
        window.admin_user_table
          .row($('#user_' + id))
          .remove()
          .draw();
      })
      .catch(error => {
        console.error(error);
        addFlash('danger', error);
      });
  };
}
