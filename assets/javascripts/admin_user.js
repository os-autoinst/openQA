function setup_admin_user() {
  window.admin_user_table = new DataTable('#users', {
    order: [[0, 'asc']]
  });

  const usersTable = document.getElementById('users');
  if (usersTable) {
    usersTable.addEventListener('change', function (event) {
      const target = event.target;
      if (target.name !== 'role' || target.type !== 'radio') return;

      const tr = target.closest('tr');
      const username = tr.querySelector('.name').textContent;
      const roleId = target.id;
      const role = document.querySelector(`label[for="${roleId}"]`).textContent;

      function findDefault(form) {
        return form.querySelector('input.default');
      }

      function rollback(form) {
        const defaultInput = findDefault(form);
        if (defaultInput) defaultInput.checked = true;
      }

      const form = target.closest('form');
      if (!confirm('Are you sure to put ' + username + ' into role: ' + role.trim() + '?')) {
        rollback(form);
        return;
      }

      const data = new FormData(form);
      const newRole = data.get('role');

      fetch(form.getAttribute('action'), {
        method: 'POST',
        body: data,
        headers: {Accept: 'application/json'},
        redirect: 'error'
      })
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
          const oldDefault = findDefault(form);
          if (oldDefault) oldDefault.classList.remove('default');
          const newDefault = form.querySelector(`input[value="${newRole}"]`);
          if (newDefault) newDefault.classList.add('default');
        })
        .catch(error => {
          console.error(error);
          rollback(form);
          addFlash('danger', `An error occurred when changing the user role: ${error}`);
        });
    });
  }

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
        const row = document.getElementById('user_' + id);
        if (row) {
          window.admin_user_table.row(row).remove().draw();
        }
      })
      .catch(error => {
        console.error(error);
        addFlash('danger', error);
      });
  };
}
