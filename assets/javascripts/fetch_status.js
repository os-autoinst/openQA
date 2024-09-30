window.runningFetchRequests = 0;

window.originalFetch = window.fetch;
window.fetch = (url, options) => {
  console.log(`Fetch: ${url}`, options);
  window.runningFetchRequests++;
  return window.originalFetch(url, options).finally(() => {
    window.runningFetchRequests--;
  });
};
