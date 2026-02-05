function backToTop() {
  const button = document.getElementById('back-to-top');
  if (!button) return;

  window.addEventListener('scroll', () => {
    // Increase the value to not show the button on shorter pages
    if (window.scrollY > 50) {
      button.style.display = 'block';
    } else {
      button.style.display = 'none';
    }
  });
  button.addEventListener('click', () => {
    const tooltip = bootstrap.Tooltip.getInstance(button);
    if (tooltip) tooltip.hide();
    window.scrollTo({top: 0, behavior: 'smooth'});
    return false;
  });
}
