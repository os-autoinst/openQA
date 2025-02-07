// propagate window.runningFetchRequests variable which
// is used in unit tests to see if there are still fetch
// requests running
window.runningFetchRequests = 0;

window.originalFetch = window.fetch;
window.fetch = (url, options) => {
  console.log(`Fetch: ${url}`, options);
  window.runningFetchRequests++;
  return window.originalFetch(url, options).finally(() => {
    window.runningFetchRequests--;
  });
};
