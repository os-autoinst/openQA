function setup_delete_account() {
  const input = document.getElementById('confirm-delete');
  const btn = document.getElementById('confirm-delete-btn');
  if (!input || !btn) return;

  input.addEventListener('input', function () {
    btn.disabled = input.value !== input.dataset.expected;
  });

  btn.addEventListener('click', function () {
    const deleteUrl = btn.dataset.deleteUrl;
    const redirectUrl = btn.dataset.redirectUrl;
    fetchWithCSRF(deleteUrl, {method: 'DELETE'}).then(function (response) {
      if (response.ok) {
        window.location.href = redirectUrl;
      } else {
        alert('Failed to delete account. Please try again.');
      }
    });
  });
}
