function checkArchiveStatus() {
  let retries = 0;
  const maxRetries = 120; // 10 minutes (120 * 5s)

  const poll = () => {
    fetch(window.location.href, {
      headers: {
        'X-Requested-With': 'XMLHttpRequest'
      }
    })
      .then(response => {
        if (response.redirected) {
          window.location.href = response.url;
          return;
        }

        if (!response.ok) {
          throw new Error(`Server returned ${response.status}: ${response.statusText}`);
        }

        if (retries < maxRetries) {
          retries++;
          setTimeout(poll, 5000);
        } else {
          showArchiveError('Timeout: Archive preparation is taking too long. Please try again later.');
        }
      })
      .catch(error => {
        console.error('Archive status check failed:', error);
        showArchiveError(`Failed to check archive status: ${error.message || error}`);
      });
  };

  setTimeout(poll, 5000);
}

function showArchiveError(message) {
  const errorContainer = document.getElementById('archive-error');
  if (errorContainer) {
    errorContainer.innerText = message;
    errorContainer.classList.remove('d-none');
    const spinner = document.querySelector('.spinner-border');
    if (spinner) {
      spinner.classList.add('d-none');
    }
  }
}

document.addEventListener('DOMContentLoaded', checkArchiveStatus);
