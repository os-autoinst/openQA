function showAddGroupModal(parentId, title) {
  const modal = document.getElementById('add_group_modal');
  const form = document.getElementById('new_group_form');
  modal.getElementsByClassName('modal-title')[0].textContent = title;
  form.dataset.createParent = parentId === undefined;
  form.dataset.parentId = parentId;
  form.reset();
  validateJobGroupForm(form);
  new bootstrap.Modal(modal).show();
  return false;
}

function showAddJobGroup(plusElement) {
  let parentId, title;
  if (plusElement) {
    const parentLiElement = plusElement.closest('li');
    parentId = parentLiElement.id.substr(13);
    if (parentId !== 'none') {
      parentId = parseInt(parentId);
    }
    title = 'Add job group in ' + parentLiElement.querySelector('.parent-group-name').textContent.trim();
  } else {
    parentId = 'none';
    title = 'Add new job group on top-level';
  }
  return showAddGroupModal(parentId, title);
}

function showAddParentGroup() {
  return showAddGroupModal(undefined, 'Add new folder');
}

function showError(message) {
  const creating = document.getElementById('new_group_creating');
  if (creating) creating.style.display = 'none';
  const error = document.getElementById('new_group_error');
  if (error) error.style.display = 'block';
  const errorMsg = document.getElementById('new_group_error_message');
  if (errorMsg) errorMsg.textContent = message ? message : 'something went wrong';
}

function fetchHtmlEntry(url, targetElement) {
  fetch(url)
    .then(response => {
      if (!response.ok) throw `Server returned ${response.status}: ${response.statusText}`;
      return response.text();
    })
    .then(html => {
      const template = document.createElement('template');
      template.innerHTML = html.trim();
      const element = template.content.firstChild;
      element.style.display = 'none';
      targetElement.prepend(element);
      const creating = document.getElementById('new_group_creating');
      if (creating) creating.style.display = 'none';
      const modalElement = document.getElementById('add_group_modal');
      const modal = bootstrap.Modal.getInstance(modalElement);
      if (modal) modal.hide();
      element.style.display = 'block';
      element.style.opacity = 0;
      setTimeout(() => {
        element.style.transition = 'opacity 0.5s';
        element.style.opacity = 1;
      }, 10);
    })
    .catch(error => {
      console.error(error);
      showError(`${error} (requesting entry HTML, group probably added though! - reload page to find out)`);
    });
}

function countEmptyInputs(form) {
  return Array.from(form.querySelectorAll('input')).reduce(
    (count, e) => count + (e.type !== 'number' && !e.value.trim().length),
    0
  );
}

function validateJobGroupForm(form) {
  const button = form.querySelector('button[type=submit]');
  let emptyInputs = countEmptyInputs(form);
  button.disabled = emptyInputs > 0;
  if (form.dataset.eventHandlersInitialized) {
    return;
  }
  form.querySelectorAll('input').forEach(input => {
    input.addEventListener('keyup', () => validateInput(input));
    input.addEventListener('change', () => validateInput(input));
  });

  function validateInput(input) {
    if (input.type === 'number') {
      return;
    }
    if (!input.value.trim().length) {
      input.classList.add('is-invalid');
    } else {
      input.classList.remove('is-invalid');
    }
    button.disabled = countEmptyInputs(form) > 0;
  }
  form.dataset.eventHandlersInitialized = true;
}

function createGroup(form) {
  const error = document.getElementById('new_group_error');
  if (error) error.style.display = 'none';
  const creating = document.getElementById('new_group_creating');
  if (creating) creating.style.display = 'block';

  let data = new FormData(form);
  let postUrl, rowUrl, targetElement;
  if (form.dataset.createParent !== 'false') {
    postUrl = form.dataset.postParentGroupUrl;
    rowUrl = form.dataset.parentGroupRowUrl;
    targetElement = document.getElementById('job_group_list');
  } else {
    postUrl = form.dataset.postJobGroupUrl;
    rowUrl = form.dataset.jobGroupRowUrl;
    const parentId = form.dataset.parentId;
    if (parentId !== 'none') {
      targetElement = document.getElementById('parent_group_' + parentId).querySelector('ul');
      data.set('parent_id', parentId);
    } else {
      targetElement = document.getElementById('job_group_list');
    }
  }

  fetchWithCSRF(postUrl, {method: 'POST', body: data})
    .then(response => {
      return response
        .json()
        .then(json => {
          // Attach the parsed JSON to the response object for further use
          return {response, json};
        })
        .catch(() => {
          // If parsing fails, handle it as a non-JSON response
          throw `Server returned ${response.status}: ${response.statusText}`;
        });
    })
    .then(({response, json}) => {
      if (!response.ok) throw `Server returned ${response.status}: ${response.statusText}<br>${json.error || ''}`;
      if (json.error) throw json.error;
      return json;
    })
    .then(response => {
      if (!response) throw 'Server returned no response';
      if (!response.id) throw 'Server returned no ID';
      fetchHtmlEntry(rowUrl + response.id, targetElement);
    })
    .catch(error => {
      console.error(error);
      showError(error);
    });

  return false;
}

let dragData = undefined;

function removeAllDropIndicators() {
  // workaround for Firefox which doesn't trigger leaveDrag when moving the mouse very fast
  document.querySelectorAll('.dragover').forEach(el => el.classList.remove('dragover'));
  document.querySelectorAll('.parent-dragover').forEach(el => el.classList.remove('parent-dragover'));
}

function checkDrop(event, parentDivElement) {
  if (dragData) {
    const parentLiElement = parentDivElement.parentElement;
    const isTopLevel = parentLiElement.parentElement.id === 'job_group_list';

    if (dragData.isParent && !isTopLevel) {
      return;
    }

    event.preventDefault();
    removeAllDropIndicators();
    parentLiElement.classList.add('dragover');
  }
}

function checkParentDrop(event, parentDivElement, enforceParentDrop, noChildDrop) {
  if (dragData) {
    if (noChildDrop && dragData.isParent) {
      return;
    }

    event.preventDefault();
    event.stopPropagation();

    removeAllDropIndicators();
    if ((dragData.enforceParentDrop = enforceParentDrop) || dragData.isParent) {
      parentDivElement.classList.add('parent-dragover');
    } else {
      parentDivElement.classList.add('dragover');
    }
  }
}

function leaveDrag(event, parentDivElement) {
  parentDivElement.classList.remove('dragover');
  parentDivElement.classList.remove('parent-dragover');
  parentDivElement.parentElement.classList.remove('dragover');
}

function concludeDrop(dropTargetElement) {
  // workaround for Firefox which doesn't emit the leaveDrag event reliably
  dropTargetElement.classList.remove('dragover');
  dropTargetElement.classList.remove('parent-dragover');

  // invalidate drag data
  dragData = undefined;

  // commit the change instantly
  saveReorganizedGroups();
}

function insertParentGroup(event, parentLiElement) {
  event.preventDefault();
  if (dragData) {
    dragData.liElement.style.display = 'none';

    if (dragData.isParent || dragData.enforceParentDrop) {
      parentLiElement.parentElement.insertBefore(dragData.liElement, parentLiElement);
    } else {
      parentLiElement.querySelector('ul').prepend(dragData.liElement);
    }
    dragData.liElement.style.display = 'block';
    dragData.liElement.style.opacity = 0;
    setTimeout(() => {
      dragData.liElement.style.transition = 'opacity 0.5s';
      dragData.liElement.style.opacity = 1;
    }, 10);
    concludeDrop(parentLiElement);
  }
}

function insertGroup(event, siblingDivElement) {
  event.preventDefault();
  if (dragData) {
    const siblingLiElement = siblingDivElement.parentElement;
    dragData.liElement.style.display = 'none';
    siblingLiElement.after(dragData.liElement);
    dragData.liElement.style.display = 'block';
    dragData.liElement.style.opacity = 0;
    setTimeout(() => {
      dragData.liElement.style.transition = 'opacity 0.5s';
      dragData.liElement.style.opacity = 1;
    }, 10);
    concludeDrop(siblingLiElement);
  }
}

function dragGroup(event, groupDivElement) {
  // workaround for Firefox which insists on having data in dataTransfer
  event.dataTransfer.setData('text/plain', 'firefox happy');

  // this variable is actually used to store the data (to preserve DOM element)
  const groupLiElement = groupDivElement.parentElement;
  dragData = {
    id: groupLiElement.id,
    liElement: groupLiElement,
    isParent: false,
    isTopLevel: groupLiElement.parentElement.id === 'job_group_list'
  };
}

function dragParentGroup(event, groupDivElement) {
  event.dataTransfer.setData('text/plain', 'firefox happy');
  const groupLiElement = groupDivElement.parentElement;
  dragData = {
    id: groupLiElement.id,
    liElement: groupLiElement,
    isParent: true,
    isTopLevel: true
  };
}

let ajaxQueries = [];
let showPanelTimeout = undefined;

function saveReorganizedGroups() {
  // wipe scheduled queries (for still uncommitted changes new queries will be added)
  ajaxQueries = [];

  // to avoid flickering, show the panel a little bit delayed
  showPanelTimeout = setTimeout(function () {
    const panel = document.getElementById('reorganize_groups_panel');
    if (panel) panel.style.display = 'block';
  }, 500);
  const progress = document.getElementById('reorganize_groups_progress');
  if (progress) progress.style.display = 'block';
  const error = document.getElementById('reorganize_groups_error');
  if (error) error.style.display = 'none';

  const jobGroupList = document.getElementById('job_group_list');
  const updateParentGroupUrl = jobGroupList.dataset.putParentGroupUrl;
  const updateJobGroupUrl = jobGroupList.dataset.putJobGroupUrl;

  // event handlers for AJAX queries
  const handleError = function (error) {
    console.error(error);
    const panel = document.getElementById('reorganize_groups_panel');
    if (panel) panel.style.display = 'block';
    const errorEl = document.getElementById('reorganize_groups_error');
    if (errorEl) errorEl.style.display = 'block';
    const progressEl = document.getElementById('reorganize_groups_progress');
    if (progressEl) progressEl.style.display = 'none';
    const errorMsg = document.getElementById('reorganize_groups_error_message');
    if (errorMsg) errorMsg.textContent = error ? error : 'something went wrong';
    window.scrollTo({top: 0, behavior: 'smooth'});
  };

  const handleSuccess = function (response, groupLi, index, parentId) {
    if (!response) {
      handleError('Server returned nothing');
      return;
    }

    if (!response.nothingToDo) {
      const id = response.id;
      if (!id) {
        handleError('Server returned no ID');
        return;
      }

      // update initial value (to avoid queries for already committed changes)
      groupLi.dataset.initialIndex = index;
      if (parentId) {
        groupLi.dataset.initialParent = parentId;
      }
    }

    if (ajaxQueries.length) {
      // do next query
      handleQuery(ajaxQueries.shift());
    } else {
      // all queries done
      if (showPanelTimeout) {
        clearTimeout(showPanelTimeout);
        showPanelTimeout = undefined;
      }
      const progressEl = document.getElementById('reorganize_groups_progress');
      if (progressEl) progressEl.style.display = 'none';
      const errorEl = document.getElementById('reorganize_groups_error');
      if (errorEl) errorEl.style.display = 'none';
      const panel = document.getElementById('reorganize_groups_panel');
      if (panel) panel.style.display = 'none';
    }
  };

  // determine what changed to make required AJAX queries
  Array.from(jobGroupList.children).forEach((groupLi, groupIndex) => {
    let isParent, groupId, updateGroupUrl;
    if (groupLi.id.indexOf('job_group_') === 0) {
      isParent = false;
      groupId = parseInt(groupLi.id.substr(10));
      updateGroupUrl = updateJobGroupUrl;
    } else if (groupLi.id.indexOf('parent_group_') === 0) {
      isParent = true;
      groupId = parseInt(groupLi.id.substr(13));
      updateGroupUrl = updateParentGroupUrl;
    }

    const parentId = groupLi.dataset.initialParent;
    if (groupIndex != groupLi.dataset.initialIndex || parentId !== 'none') {
      // index of parent group changed -> update sort order
      ajaxQueries.push({
        url: updateGroupUrl + groupId,
        method: 'PUT',
        body: {
          sort_order: groupIndex,
          parent_id: 'none',
          drag: 1
        },
        success: function (response) {
          handleSuccess(response, groupLi, groupIndex);
        },
        error: handleError
      });
    }

    if (isParent) {
      Array.from(groupLi.querySelector('ul').children).forEach((jobGroupLi, childGroupIndex) => {
        const jobGroupId = parseInt(jobGroupLi.id.substr(10));

        if (childGroupIndex != jobGroupLi.dataset.initialIndex || groupId != jobGroupLi.dataset.initialParent) {
          // index or parent of job group changed -> update parent and sort order
          ajaxQueries.push({
            url: updateJobGroupUrl + jobGroupId,
            method: 'PUT',
            body: {
              sort_order: childGroupIndex,
              parent_id: groupId,
              drag: 1
            },
            success: function (response) {
              handleSuccess(response, jobGroupLi, childGroupIndex, groupId);
            },
            error: handleError
          });
        }
      });
    }
  });

  if (ajaxQueries.length) {
    handleQuery(ajaxQueries.shift());
  } else {
    handleSuccess({nothingToDo: true});
  }
  return false;
}

function handleQuery(query) {
  const url = query.url;
  delete query.url;
  const success = query.success;
  delete query.success;
  const error = query.error;
  delete query.error;
  const body = new FormData();
  for (const key in query.body) {
    body.append(key, query.body[key]);
  }
  query.body = body;
  fetchWithCSRF(url, query)
    .then(response => {
      return response
        .json()
        .then(json => {
          // Attach the parsed JSON to the response object for further use
          return {response, json};
        })
        .catch(() => {
          // If parsing fails, handle it as a non-JSON response
          throw `Server returned ${response.status}: ${response.statusText}`;
        });
    })
    .then(({response, json}) => {
      return json;
    })
    .then(success)
    .catch(error);
}
function deleteGroup(elem, isParent) {
  const li = elem.closest('li');
  const idAttr = li.id;
  const id = parseInt(idAttr.replace(isParent ? 'parent_group_' : 'job_group_', ''));
  const name = li.querySelector(isParent ? '.parent-group-name' : 'span > a').textContent.trim();
  const type = isParent ? 'parent group' : 'job group';

  if (!confirm(`Are you sure you want to delete the ${type} "${name}"?`)) {
    return false;
  }

  const url = `/api/v1/${isParent ? 'parent_groups' : 'job_groups'}/${id}`;

  fetchWithCSRF(url, {method: 'DELETE'})
    .then(response => {
      if (!response.ok) {
        return response.json().then(json => {
          throw json.error || response.statusText;
        });
      }
      return response.json();
    })
    .then(() => {
      li.style.transition = 'opacity 0.5s';
      li.style.opacity = 0;
      setTimeout(() => li.remove(), 500);
    })
    .catch(error => {
      console.error(error);
      alert(`Error deleting ${type}: ${error}`);
    });

  return false;
}
