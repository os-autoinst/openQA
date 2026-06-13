function toggleFullscreenMode(fullscreen) {
  // change ID of main container (to change applied CSS rules)
  const content = document.getElementById('content') || document.getElementById('content_fullscreen');
  if (content) {
    content.id = fullscreen ? 'content_fullscreen' : 'content';
  }

  // change visibility of some elements
  document.querySelectorAll('.navbar, .footer, .jumbotron, #group_description').forEach(el => {
    el.style.display = fullscreen ? 'none' : '';
  });

  // toggle navbar visibility
  const navbar = document.querySelector('.navbar');
  if (!navbar) {
    return;
  }
  const navbarHeight = navbar.offsetHeight;
  let handler = document.showNavbarIfItWouldContainMouse;
  if (!fullscreen) {
    if (handler === undefined) {
      return;
    }
    document.removeEventListener('mousemove', handler, false);
    navbar.style.display = '';
    return;
  }
  handler = document.showNavbarIfItWouldContainMouse = function (e) {
    const mouseY = e.clientY || e.pageY;
    if (mouseY <= navbarHeight || navbar.querySelectorAll("[aria-expanded='true']").length !== 0) {
      navbar.style.display = '';
    } else if (mouseY > navbarHeight && !document.querySelector('li.dropdown.open')) {
      navbar.style.display = 'none';
    }
  };
  document.addEventListener('mousemove', handler, false);
}

function autoRefresh(fullscreen, interval) {
  if (!fullscreen) {
    return;
  }
  const refresh = function () {
    fetch(location.href)
      .then(response => response.text())
      .then(html => {
        const parser = new DOMParser();
        const doc = parser.parseFromString(html, 'text/html');
        ['build-results', 'comments-preview'].forEach(id => {
          const newEl = doc.getElementById(id);
          const oldEl = document.getElementById(id);
          if (newEl && oldEl) {
            oldEl.innerHTML = newEl.innerHTML;
            if (id === 'build-results' && window.timeago && typeof window.timeago.format === 'function') {
              oldEl.querySelectorAll('.timeago').forEach(el => {
                const date = el.getAttribute('title') || el.getAttribute('datetime');
                if (date) {
                  el.textContent = window.timeago.format(date);
                }
              });
            }
          }
        });
      });
  };
  const initialize = function () {
    setInterval(refresh, interval * 1000);
  };
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initialize);
  } else {
    initialize();
  }
}
