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
    filterForm.addEventListener('submit', function () {
      const currentQuery = window.location.search.substring(1);
      const formData = new FormData(filterForm);
      const newQuery = new URLSearchParams(formData).toString();

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
    const checkboxes = container.querySelectorAll('input[type="checkbox"]:not(.filter-bulk-master)');
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
        mb3.querySelectorAll('input[type="checkbox"]:not(.filter-bulk-master)').forEach(cb => {
          cb.checked = isChecked;
        });
        return;
      }

      const invert = e.target.closest('.filter-bulk-invert');
      if (invert) {
        e.preventDefault();
        const mb3 = invert.closest('.mb-3');
        mb3.querySelectorAll('input[type="checkbox"]:not(.filter-bulk-master)').forEach(cb => {
          cb.checked = !cb.checked;
        });
        updateMasterCheckbox(mb3);
      }
    });

    container.addEventListener('change', function (e) {
      if (e.target.matches('input[type="checkbox"]:not(.filter-bulk-master)')) {
        updateMasterCheckbox(e.target.closest('.mb-3'));
      }
    });

    updateMasterCheckbox(container);
  });
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
