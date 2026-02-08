function setupFilterForm(options) {
  // make filter form expandable
  const cardHeader = document.querySelector('#filter-panel .card-header');
  if (cardHeader) {
    cardHeader.addEventListener('click', function () {
      const cardBody = document.querySelector('#filter-panel .card-body');
      if (cardBody) {
        $(cardBody).toggle(200);
        if (document.getElementById('filter-panel').classList.contains('filter-panel-bottom')) {
          window.scrollTo({top: document.documentElement.scrollHeight, behavior: 'smooth'});
        }
      }
    });
  }

  document.querySelectorAll('#filter-panel .help_popover').forEach(helpPopover => {
    helpPopover.addEventListener('click', function (event) {
      event.stopPropagation();
    });
  });

  if (options && options.preventLoadingIndication) {
    return;
  }

  const filterForm = document.getElementById('filter-form');
  if (filterForm) {
    filterForm.addEventListener('submit', function (event) {
      event.preventDefault();
      const currentQuery = window.location.search.substring(1);
      const formData = new FormData(filterForm);

      // optimize results and states to use negative filters if shorter
      ['result', 'state'].forEach(key => {
        const checkboxes = Array.from(filterForm.querySelectorAll(`input[name="${key}"]:not(.filter-meta)`));
        const checked = checkboxes.filter(cb => cb.checked);
        const unchecked = checkboxes.filter(cb => !cb.checked);
        if (checked.length > 1 && unchecked.length > 0 && unchecked.length < checked.length) {
          formData.delete(key);
          unchecked.forEach(cb => formData.append(`${key}__not`, cb.value));
        }
      });

      const params = new URLSearchParams(formData);

      // remove redundant constituent values if meta-values are present
      if (options && options.metaMapping) {
        ['result', 'state'].forEach(key => {
          const mapping = options.metaMapping[key];
          if (!mapping) return;
          const currentValues = params.getAll(key);
          if (currentValues.length === 0) return;

          let newValues = [...currentValues];
          Object.keys(mapping).forEach(metaValue => {
            if (currentValues.includes(metaValue)) {
              const constituents = mapping[metaValue];
              newValues = newValues.filter(val => !constituents.includes(val));
            }
          });

          if (newValues.length !== currentValues.length) {
            params.delete(key);
            newValues.forEach(val => params.append(key, val));
          }
        });
      }

      const keysToDelete = [];
      params.forEach((val, key) => {
        if (val === '') keysToDelete.push(key);
      });
      keysToDelete.forEach(key => params.delete(key));
      const newQuery = params.toString();

      if (newQuery !== currentQuery) {
        // show progress indication
        filterForm.hidden = true;
        const cardBody = document.querySelector('#filter-panel .card-body');
        if (cardBody) {
          const progress = document.createElement('span');
          progress.id = 'filter-progress';
          progress.innerHTML = '<i class="fa fa-cog fa-spin fa-2x fa-fw"></i> <span>Applying filter…</span>';
          cardBody.appendChild(progress);
        }
        window.location.search = newQuery;
      }
    });
  }

  const resetBtn = document.getElementById('filter-reset-button');
  if (resetBtn) {
    resetBtn.addEventListener('click', function () {
      if (!filterForm) return;
      filterForm.querySelectorAll('input[type="text"], input[type="number"]').forEach(input => {
        input.value = '';
      });
      filterForm.querySelectorAll('input[type="checkbox"]').forEach(input => {
        input.checked = false;
        input.indeterminate = false;
      });
      filterForm.querySelectorAll('input[hidden]').forEach(input => {
        input.remove();
      });
      $(filterForm).find('select').val([]).trigger('chosen:updated');
      document.querySelector('#filter-panel .card-header span').textContent =
        'no filter present, click to toggle filter form';
    });
  }

  const updateMasterCheckbox = function (container) {
    const master = container.querySelector('.filter-bulk-master');
    if (!master) return;
    const checkboxes = container.querySelectorAll('input[type="checkbox"]:not(.filter-bulk-master):not(.filter-meta)');
    const checkedCount = Array.from(checkboxes).filter(cb => cb.checked).length;

    if (checkedCount === 0) {
      master.checked = false;
      master.indeterminate = false;
    } else if (checkedCount === checkboxes.length) {
      master.checked = true;
      master.indeterminate = false;
    } else {
      master.checked = false;
      master.indeterminate = true;
    }
  };

  document.querySelectorAll('#filter-results, #filter-states').forEach(container => {
    container.addEventListener('click', function (e) {
      const master = e.target.closest('.filter-bulk-master');
      if (master) {
        const mb3 = master.closest('.mb-3');
        const isChecked = master.checked;
        mb3.querySelectorAll('input[type="checkbox"]:not(.filter-bulk-master):not(.filter-meta)').forEach(cb => {
          cb.checked = isChecked;
        });
        return;
      }

      const invert = e.target.closest('.filter-bulk-invert');
      if (invert) {
        e.preventDefault();
        const mb3 = invert.closest('.mb-3');
        mb3.querySelectorAll('input[type="checkbox"]:not(.filter-bulk-master):not(.filter-meta)').forEach(cb => {
          cb.checked = !cb.checked;
        });
        updateMasterCheckbox(mb3);
      }
    });

    container.addEventListener('change', function (e) {
      if (e.target.matches('input[type="checkbox"]:not(.filter-bulk-master):not(.filter-meta)')) {
        updateMasterCheckbox(e.target.closest('.mb-3'));
      }
    });

    updateMasterCheckbox(container);
  });

  if (options && options.metaMapping) {
    const filterForm = document.getElementById('filter-form');
    if (filterForm) {
      ['result', 'state'].forEach(key => {
        const mapping = options.metaMapping[key];
        if (!mapping) return;
        Object.keys(mapping).forEach(metaValue => {
          const metaCheckbox = filterForm.querySelector(`input[name="${key}"][value="${metaValue}"]`);
          if (!metaCheckbox) return;
          metaCheckbox.addEventListener('change', function () {
            const isChecked = this.checked;
            mapping[metaValue].forEach(val => {
              const cb = filterForm.querySelector(`input[name="${key}"][value="${val}"]`);
              if (cb) {
                cb.checked = isChecked;
                cb.dispatchEvent(new Event('change', {bubbles: true}));
              }
            });
          });
        });
      });
    }
  }
}

function parseFilterArguments(paramHandler) {
  const params = new URLSearchParams(window.location.search);
  const filterLabels = [];
  const form = document.getElementById('filter-form');
  const hiddenInputs = [];

  params.forEach((val, key) => {
    if (val.length < 1) return;
    const filterLabel = paramHandler(key, val);
    if (filterLabel) {
      filterLabels.push(filterLabel);
    } else {
      const input = document.createElement('input');
      input.value = val;
      input.name = key;
      input.hidden = true;
      hiddenInputs.push(input);
    }
  });

  if (form) {
    form.append(...hiddenInputs);
  }

  if (filterLabels.length > 0) {
    document.querySelector('#filter-panel .card-header span').textContent = 'current: ' + filterLabels.join(', ');
  }
  return filterLabels;
}
