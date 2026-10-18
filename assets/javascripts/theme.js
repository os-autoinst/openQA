function applyTheme() {
  const html = document.documentElement;
  let theme = html.dataset.themePreference;
  if (theme === 'detect') theme = window.matchMedia('(prefers-color-scheme: dark)').matches === true ? 'dark' : 'light';
  if (theme === 'dark' && html.dataset.halloweenSeason === 'true') theme = 'dark_halloween';
  html.dataset.bsTheme = theme === 'dark_halloween' ? 'dark' : theme;
  if (theme === 'dark_halloween') html.dataset.halloween = 'true';
}

applyTheme();
