(() => {
  const html = document.documentElement;
  let theme = html.dataset.themePreference;
  if (theme === 'detect') theme = window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
  html.dataset.bsTheme = theme;
})();
