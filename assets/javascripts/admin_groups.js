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
  $.ajax({
    url: url,
    method: 'GET',
    success: function (response) {
      var element = $(response);
      element.hide();
      targetElement.prepend(element);
      $('#new_group_creating').hide();
      $('#add_group_modal').modal('hide');
      element.fadeIn('slow');
    },
    error: function (xhr, ajaxOptions, thrownError) {
      showError(thrownError + ' (requesting entry HTML, group probably added though! - reload page to find out)');
    }
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

  let data = $(form).serialize();
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
      data += '&parent_id=' + parentId;
    } else {
      targetElement = $('#job_group_list');
    }
  }

  $.ajax({
    url: postUrl,
    method: 'POST',
    data: data,
    success: function (response) {
      if (!response) {
        showError('Server returned no response');
        return;
      }
      var id = response.id;
      if (!id) {
        showError('Server returned no ID');
        return;
      }
      fetchHtmlEntry(rowUrl + response.id, targetElement);
    },
    error: function (xhr, ajaxOptions, thrownError) {
      if (xhr.responseJSON.error) {
        showError(xhr.responseJSON.error);
      } else {
        showError(thrownError);
      }
    }
  });

  return false;
}

var dragData = undefined;

function removeAllDropIndicators() {
  // workaround for Firefox which doesn't trigger leaveDrag when moving the mouse very fast
  $('.dragover').removeClass('dragover');
  $('.parent-dragover').removeClass('parent-dragover');
}

function checkDrop(event, parentDivElement) {
  if (dragData) {
    var parentLiElement = parentDivElement.parentElement;
    var isTopLevel = parentLiElement.parentElement.id === 'job_group_list';

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
    var siblingLiElement = siblingDivElement.parentElement;
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
  var groupLiElement = groupDivElement.parentElement;
  dragData = {
    id: groupLiElement.id,
    liElement: $(groupLiElement),
    isParent: false,
    isTopLevel: groupLiElement.parentElement.id === 'job_group_list'
  };
}

function dragParentGroup(event, groupDivElement) {
  event.dataTransfer.setData('make', 'firefox happy');
  var groupLiElement = groupDivElement.parentElement;
  dragData = {
    id: groupLiElement.id,
    liElement: $(groupLiElement),
    isParent: true,
    isTopLevel: true
  };
}

var ajaxQueries = [];
var showPanelTimeout = undefined;

function saveReorganizedGroups() {
  // wipe scheduled queries (for still uncommitted changes new queries will be added)
  ajaxQueries = [];

  // to avoid flickering, show the panel a little bit delayed
  showPanelTimeout = setTimeout(function () {
    $('#reorganize_groups_panel').show();
  }, 500);
  $('#reorganize_groups_progress').show();
  $('#reorganize_groups_error').hide();

  var jobGroupList = $('#job_group_list');
  var updateParentGroupUrl = jobGroupList.data('put-parent-group-url');
  var updateJobGroupUrl = jobGroupList.data('put-job-group-url');

  // event handlers for AJAX queries
  var handleError = function (xhr, ajaxOptions, thrownError) {
    $('#reorganize_groups_panel').show();
    $('#reorganize_groups_error').show();
    $('#reorganize_groups_progress').hide();
    $('#reorganize_groups_error_message').text(thrownError ? thrownError : 'something went wrong');
    $('html, body').animate({scrollTop: 0}, 1000);
  };

  var handleSuccess = function (response, groupLi, index, parentId) {
    if (!response) {
      handleError(undefined, undefined, 'Server returned nothing');
      return;
    }

    if (!response.nothingToDo) {
      var id = response.id;
      if (!id) {
        handleError(undefined, undefined, 'Server returned no ID');
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
      $.ajax(ajaxQueries.shift());
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
        data: {
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
          var jobGroupLi = $(this);
          var jobGroupId = parseInt(this.id.substr(10));

          if (childGroupIndex != jobGroupLi.data('initial-index') || groupId != jobGroupLi.data('initial-parent')) {
            // index or parent of job group changed -> update parent and sort order
            ajaxQueries.push({
              url: updateJobGroupUrl + jobGroupId,
              method: 'PUT',
              data: {
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
    $.ajax(ajaxQueries.shift());
  } else {
    handleSuccess({nothingToDo: true});
  }
  return false;
}
