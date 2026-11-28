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

// DataTables 3.x performs its Ajax requests via XMLHttpRequest instead of fetch() or jQuery's
// $.ajax so they are not covered above and would let wait_for_ajax return before the tables are
// drawn. Decrement only in the complete callback because the draw happens in the success callback.
if (window.DataTable?.util?.ajax) {
  const dataTablesAjax = DataTable.util.ajax;
  DataTable.util.ajax = options => {
    let finished = false;
    const finish = () => {
      if (finished) return;
      finished = true;
      window.runningFetchRequests--;
    };
    window.runningFetchRequests++;
    const complete = options.complete;
    options.complete = function () {
      try {
        if (complete) complete.apply(this, arguments);
      } finally {
        finish();
      }
    };
    const xhr = dataTablesAjax(options);
    xhr.addEventListener('abort', finish);
    return xhr;
  };
}
