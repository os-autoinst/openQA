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
    const parentLiElement = $(plusElement).closest('li');
    parentId = parentLiElement.prop('id').substr(13);
    if (parentId !== 'none') {
      parentId = parseInt(parentId);
    }
    title = 'Add job group in ' + parentLiElement.find('.parent-group-name').text().trim();
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
  $('#new_group_creating').hide();
  $('#new_group_error').show();
  $('#new_group_error_message').text(message ? message : 'something went wrong');
}

function fetchHtmlEntry(url, targetElement) {
  fetch(url)
    .then(response => {
      if (!response.ok) throw `Server returned ${response.status}: ${response.statusText}`;
      return response.text();
    })
    .then(response => {
      const element = $(response);
      element.hide();
      targetElement.prepend(element);
      $('#new_group_creating').hide();
      $('#add_group_modal').modal('hide');
      element.fadeIn('slow');
    })
    .catch(error => {
      console.error(error);
      showError(`${error} (requesting entry HTML, group probably added though! - reload page to find out)`);
    });
}

function countEmptyInputs(form) {
  return Array.from(form.querySelectorAll('input')).reduce(
    (count, e) => count + (e.type !== 'number' && !jQuery.trim(e.value).length),
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
  $('input', form).on('keyup change', function () {
    if (this.type === 'number') {
      return;
    }
    if (!jQuery.trim(this.value).length) {
      this.classList.add('is-invalid');
      button.disabled = ++emptyInputs;
    } else {
      this.classList.remove('is-invalid');
      button.disabled = --emptyInputs > 0;
    }
  });
  form.dataset.eventHandlersInitialized = true;
}

function createGroup(form) {
  $('#new_group_error').hide();
  $('#new_group_creating').show();

  let data = new FormData(form);
  let postUrl, rowUrl, targetElement;
  if (form.dataset.createParent !== 'false') {
    postUrl = form.dataset.postParentGroupUrl;
    rowUrl = form.dataset.parentGroupRowUrl;
    targetElement = $('#job_group_list');
  } else {
    postUrl = form.dataset.postJobGroupUrl;
    rowUrl = form.dataset.jobGroupRowUrl;
    const parentId = form.dataset.parentId;
    if (parentId !== 'none') {
      targetElement = $('#parent_group_' + parentId).find('ul');
      data.set('parent_id', parentId);
    } else {
      targetElement = $('#job_group_list');
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
  $('.dragover').removeClass('dragover');
  $('.parent-dragover').removeClass('parent-dragover');
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
    $(parentLiElement).addClass('dragover');
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
      $(parentDivElement).addClass('parent-dragover');
    } else {
      $(parentDivElement).addClass('dragover');
    }
  }
}

function leaveDrag(event, parentDivElement) {
  $(parentDivElement).removeClass('dragover');
  $(parentDivElement).removeClass('parent-dragover');
  $(parentDivElement.parentElement).removeClass('dragover');
}

function concludeDrop(dropTargetElement) {
  // workaround for Firefox which doesn't emit the leaveDrag event reliably
  $(dropTargetElement).removeClass('dragover');
  $(dropTargetElement).removeClass('parent-dragover');

  // invalidate drag data
  dragData = undefined;

  // commit the change instantly
  saveReorganizedGroups();
}

function insertParentGroup(event, parentLiElement) {
  event.preventDefault();
  if (dragData) {
    dragData.liElement.hide();

    if (dragData.isParent || dragData.enforceParentDrop) {
      dragData.liElement.insertBefore($(parentLiElement).parent());
    } else {
      dragData.liElement.prependTo($(parentLiElement).parent().find('ul'));
    }
    dragData.liElement.fadeIn('slow');
    concludeDrop(parentLiElement);
  }
}

function insertGroup(event, siblingDivElement) {
  event.preventDefault();
  if (dragData) {
    const siblingLiElement = siblingDivElement.parentElement;
    dragData.liElement.hide();
    dragData.liElement.insertAfter($(siblingLiElement));
    dragData.liElement.fadeIn('slow');
    concludeDrop(siblingLiElement);
  }
}

function dragGroup(event, groupDivElement) {
  // workaround for Firefox which insists on having data in dataTransfer
  event.dataTransfer.setData('make', 'firefox happy');

  // this variable is actually used to store the data (to preserve DOM element)
  const groupLiElement = groupDivElement.parentElement;
  dragData = {
    id: groupLiElement.id,
    liElement: $(groupLiElement),
    isParent: false,
    isTopLevel: groupLiElement.parentElement.id === 'job_group_list'
  };
}

function dragParentGroup(event, groupDivElement) {
  event.dataTransfer.setData('make', 'firefox happy');
  const groupLiElement = groupDivElement.parentElement;
  dragData = {
    id: groupLiElement.id,
    liElement: $(groupLiElement),
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
    $('#reorganize_groups_panel').show();
  }, 500);
  $('#reorganize_groups_progress').show();
  $('#reorganize_groups_error').hide();

  const jobGroupList = $('#job_group_list');
  const updateParentGroupUrl = jobGroupList.data('put-parent-group-url');
  const updateJobGroupUrl = jobGroupList.data('put-job-group-url');

  // event handlers for AJAX queries
  const handleError = function (error) {
    console.error(error);
    $('#reorganize_groups_panel').show();
    $('#reorganize_groups_error').show();
    $('#reorganize_groups_progress').hide();
    $('#reorganize_groups_error_message').text(error ? error : 'something went wrong');
    $('html, body').animate({scrollTop: 0}, 1000);
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
      groupLi.data('initial-index', index);
      if (parentId) {
        groupLi.data('initial-parent', parentId);
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
      $('#reorganize_groups_progress').hide();
      $('#reorganize_groups_error').hide();
      $('#reorganize_groups_panel').hide();
    }
  };

  // determine what changed to make required AJAX queries
  jobGroupList.children('li').each(function (groupIndex) {
    const groupLi = $(this);
    let isParent, groupId, updateGroupUrl;
    if (this.id.indexOf('job_group_') === 0) {
      isParent = false;
      groupId = parseInt(this.id.substr(10));
      updateGroupUrl = updateJobGroupUrl;
    } else if (this.id.indexOf('parent_group_') === 0) {
      isParent = true;
      groupId = parseInt(this.id.substr(13));
      updateGroupUrl = updateParentGroupUrl;
    }

    const parentId = groupLi.data('initial-parent');
    if (groupIndex != groupLi.data('initial-index') || parentId !== 'none') {
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
      groupLi
        .find('ul')
        .children('li')
        .each(function (childGroupIndex) {
          const jobGroupLi = $(this);
          const jobGroupId = parseInt(this.id.substr(10));

          if (childGroupIndex != jobGroupLi.data('initial-index') || groupId != jobGroupLi.data('initial-parent')) {
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
  const li = $(elem).closest('li');
  const idAttr = li.attr('id');
  const id = parseInt(idAttr.replace(isParent ? 'parent_group_' : 'job_group_', ''));
  const name = li
    .find(isParent ? '.parent-group-name' : 'span > a')
    .text()
    .trim();
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
      li.fadeOut('slow', function () {
        $(this).remove();
      });
    })
    .catch(error => {
      console.error(error);
      alert(`Error deleting ${type}: ${error}`);
    });

  return false;
}
