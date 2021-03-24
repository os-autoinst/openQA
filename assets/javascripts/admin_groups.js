function showAddJobGroup (plusElement) {
  if (plusElement) {
    const parentLiElement = $(plusElement).closest('li')
    var parentId = parentLiElement.prop('id').substr(13)
    if (parentId !== 'none') {
      parentId = parseInt(parentId)
    }
    var title = 'Add job group in ' + parentLiElement.find('.parent-group-name').text().trim()
  } else {
    var parentId = 'none'
    var title = 'Add new job group on top-level'
  }

  const formElement = $('#new_group_form')
  formElement.data('create-parent', false)
  formElement.data('parent-id', parentId)
  formElement.trigger('reset')

  const addGroupElement = $('#add_group_modal')

  addGroupElement.find('.modal-title').text(title)
  addGroupElement.modal()
  checkJobGroupForm('#new_group_form')
  return false
}

function showAddParentGroup () {
  const formElement = $('#new_group_form')
  formElement.data('create-parent', true)
  formElement.trigger('reset')

  const addGroupElement = $('#add_group_modal')
  addGroupElement.find('.modal-title').text('Add new folder')
  addGroupElement.modal()
  checkJobGroupForm('#new_group_form')
  return false
}

function showError (message) {
  $('#new_group_creating').hide()
  $('#new_group_error').show()
  $('#new_group_error_message').text(message || 'something went wrong')
}

function fetchHtmlEntry (url, targetElement) {
  $.ajax({
    url: url,
    method: 'GET',
    success: function (response) {
      const element = $(response)
      element.hide()
      targetElement.prepend(element)
      $('#new_group_creating').hide()
      $('#add_group_modal').modal('hide')
      element.fadeIn('slow')
    },
    error: function (xhr, ajaxOptions, thrownError) {
      showError(thrownError + ' (requesting entry HTML, group probably added though! - reload page to find out)')
    }
  })
}

function _checkJobGroupInputs (formID) {
  let empty = false
  $('.form-group input', formID).each(function () {
    const trimmed = jQuery.trim($(this).val())
    if (!trimmed.length) {
      empty = true
    }
  })
  return empty
}

function checkJobGroupForm (formID) {
  const empty = _checkJobGroupInputs(formID)
  if (empty) {
    $('button[type=submit]', formID).attr('disabled', 'disabled')
  }
  $('.form-group input', formID).on('keyup change', function () {
    const trimmed = jQuery.trim($(this).val())
    if (!trimmed.length) {
      $(this).addClass('is-invalid')
      $('button[type=submit]', formID).attr('disabled', 'disabled')
    } else {
      $(this).removeClass('is-invalid')
      $('button[type=submit]', formID).removeAttr('disabled')
    }
  })
}

function createGroup (form) {
  const editorForm = $(form)
  $('#new_group_error').hide()
  $('#new_group_creating').show()

  let data = editorForm.serialize()
  if (editorForm.data('create-parent')) {
    var postUrl = editorForm.data('post-parent-group-url')
    var rowUrl = editorForm.data('parent-group-row-url')
    var targetElement = $('#job_group_list')
  } else {
    var postUrl = editorForm.data('post-job-group-url')
    var rowUrl = editorForm.data('job-group-row-url')
    const parentId = editorForm.data('parent-id')
    if (parentId !== 'none') {
      var targetElement = $('#parent_group_' + parentId).find('ul')
      data += '&parent_id=' + parentId
    } else {
      var targetElement = $('#job_group_list')
    }
  }

  $.ajax({
    url: postUrl,
    method: 'POST',
    data: data,
    success: function (response) {
      if (!response) {
        showError('Server returned no response')
        return
      }
      const id = response.id
      if (!id) {
        showError('Server returned no ID')
        return
      }
      fetchHtmlEntry(rowUrl + response.id, targetElement)
    },
    error: function (xhr, ajaxOptions, thrownError) {
      if (xhr.responseJSON.error) {
        showError(xhr.responseJSON.error)
      } else {
        showError(thrownError)
      }
    }
  })

  return false
}

let dragData

function removeAllDropIndicators () {
  // workaround for Firefox which doesn't trigger leaveDrag when moving the mouse very fast
  $('.dragover').removeClass('dragover')
  $('.parent-dragover').removeClass('parent-dragover')
}

function checkDrop (event, parentDivElement) {
  if (dragData) {
    const parentLiElement = parentDivElement.parentElement
    const isTopLevel = parentLiElement.parentElement.id === 'job_group_list'

    if (dragData.isParent && !isTopLevel) {
      return
    }

    event.preventDefault()
    removeAllDropIndicators()
    $(parentLiElement).addClass('dragover')
  }
}

function checkParentDrop (event, parentDivElement, enforceParentDrop, noChildDrop) {
  if (dragData) {
    if (noChildDrop && dragData.isParent) {
      return
    }

    event.preventDefault()
    event.stopPropagation()

    removeAllDropIndicators()
    if ((dragData.enforceParentDrop = enforceParentDrop) || dragData.isParent) {
      $(parentDivElement).addClass('parent-dragover')
    } else {
      $(parentDivElement).addClass('dragover')
    }
  }
}

function leaveDrag (event, parentDivElement) {
  $(parentDivElement).removeClass('dragover')
  $(parentDivElement).removeClass('parent-dragover')
  $(parentDivElement.parentElement).removeClass('dragover')
}

function concludeDrop (dropTargetElement) {
  // workaround for Firefox which doesn't emit the leaveDrag event reliably
  $(dropTargetElement).removeClass('dragover')
  $(dropTargetElement).removeClass('parent-dragover')

  // invalidate drag data
  dragData = undefined

  // commit the change instantly
  saveReorganizedGroups()
}

function insertParentGroup (event, parentLiElement) {
  event.preventDefault()
  if (dragData) {
    dragData.liElement.hide()

    if (dragData.isParent || dragData.enforceParentDrop) {
      dragData.liElement.insertBefore($(parentLiElement).parent())
    } else {
      dragData.liElement.prependTo($(parentLiElement).parent().find('ul'))
    }
    dragData.liElement.fadeIn('slow')
    concludeDrop(parentLiElement)
  }
}

function insertGroup (event, siblingDivElement) {
  event.preventDefault()
  if (dragData) {
    const siblingLiElement = siblingDivElement.parentElement
    dragData.liElement.hide()
    dragData.liElement.insertAfter($(siblingLiElement))
    dragData.liElement.fadeIn('slow')
    concludeDrop(siblingLiElement)
  }
}

function dragGroup (event, groupDivElement) {
  // workaround for Firefox which insists on having data in dataTransfer
  event.dataTransfer.setData('make', 'firefox happy')

  // this variable is actually used to store the data (to preserve DOM element)
  const groupLiElement = groupDivElement.parentElement
  dragData = {
    id: groupLiElement.id,
    liElement: $(groupLiElement),
    isParent: false,
    isTopLevel: groupLiElement.parentElement.id === 'job_group_list'
  }
}

function dragParentGroup (event, groupDivElement) {
  event.dataTransfer.setData('make', 'firefox happy')
  const groupLiElement = groupDivElement.parentElement
  dragData = {
    id: groupLiElement.id,
    liElement: $(groupLiElement),
    isParent: true,
    isTopLevel: true
  }
}

let ajaxQueries = []
let showPanelTimeout

function saveReorganizedGroups () {
  // wipe scheduled queries (for still uncommited changes new queries will be added)
  ajaxQueries = []

  // to avoid flickering, show the panel a litle bit delayed
  showPanelTimeout = setTimeout(function () {
    $('#reorganize_groups_panel').show()
  }, 500)
  $('#reorganize_groups_progress').show()
  $('#reorganize_groups_error').hide()

  const jobGroupList = $('#job_group_list')
  const updateParentGroupUrl = jobGroupList.data('put-parent-group-url')
  const updateJobGroupUrl = jobGroupList.data('put-job-group-url')

  // event handlers for AJAX queries
  const handleError = function (xhr, ajaxOptions, thrownError) {
    $('#reorganize_groups_panel').show()
    $('#reorganize_groups_error').show()
    $('#reorganize_groups_progress').hide()
    $('#reorganize_groups_error_message').text(thrownError || 'something went wrong')
    $('html, body').animate({ scrollTop: 0 }, 1000)
  }

  const handleSuccess = function (response, groupLi, index, parentId) {
    if (!response) {
      handleError(undefined, undefined, 'Server returned nothing')
      return
    }

    if (!response.nothingToDo) {
      const id = response.id
      if (!id) {
        handleError(undefined, undefined, 'Server returned no ID')
        return
      }

      // update initial value (to avoid queries for already commited changes)
      groupLi.data('initial-index', index)
      if (parentId) {
        groupLi.data('initial-parent', parentId)
      }
    }

    if (ajaxQueries.length) {
      // do next query
      $.ajax(ajaxQueries.shift())
    } else {
      // all queries done
      if (showPanelTimeout) {
        clearTimeout(showPanelTimeout)
        showPanelTimeout = undefined
      }
      $('#reorganize_groups_progress').hide()
      $('#reorganize_groups_error').hide()
      $('#reorganize_groups_panel').hide()
    }
  }

  // determine what changed to make required AJAX queries
  jobGroupList.children('li').each(function (groupIndex) {
    const groupLi = $(this)

    if (this.id.indexOf('job_group_') === 0) {
      var isParent = false
      var groupId = parseInt(this.id.substr(10))
      var updateGroupUrl = updateJobGroupUrl
    } else if (this.id.indexOf('parent_group_') === 0) {
      var isParent = true
      var groupId = parseInt(this.id.substr(13))
      var updateGroupUrl = updateParentGroupUrl
    }
    const parentId = groupLi.data('initial-parent')

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
          handleSuccess(response, groupLi, groupIndex)
        },
        error: handleError
      })
    }

    if (isParent) {
      groupLi.find('ul').children('li').each(function (childGroupIndex) {
        const jobGroupLi = $(this)
        const jobGroupId = parseInt(this.id.substr(10))

        if (childGroupIndex != jobGroupLi.data('initial-index') ||
                    groupId != jobGroupLi.data('initial-parent')) {
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
              handleSuccess(response, jobGroupLi, childGroupIndex, groupId)
            },
            error: handleError
          })
        }
      })
    }
  })

  if (ajaxQueries.length) {
    $.ajax(ajaxQueries.shift())
  } else {
    handleSuccess({ nothingToDo: true })
  }
  return false
}
