window.enableStatusUpdates = (parseQueryParams().status_updates || []).every(p => Number.parseInt(p) !== 0);
