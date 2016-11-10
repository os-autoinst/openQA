function showAddJobGroup(plusElement) {
    if(plusElement) {
        var parentLiElement = $(plusElement).closest('li');
        var parentId = parentLiElement.prop('id').substr(13);
        if(parentId !== 'none') {
            parentId = parseInt(parentId);
        }
        var title = 'Add job group in ' + parentLiElement.find('.parent-group-name').text().trim();
    } else {
        var parentId = 'none';
        var title = 'Add new job group on top-level';
    }

    var formElement = $('#new_group_form');
    formElement.data('create-parent', false);
    formElement.data('parent-id', parentId);
    formElement.trigger('reset');

    var addGroupElement = $('#add_group_modal');

    addGroupElement.find('.modal-title').text(title);
    addGroupElement.modal();
    return false;
}

function showAddParentGroup() {
    var formElement = $('#new_group_form');
    formElement.data('create-parent', true);
    formElement.trigger('reset');

    var addGroupElement = $('#add_group_modal');
    addGroupElement.find('.modal-title').text('Add new folder');
    addGroupElement.modal();
    return false;
}

function showError(message) {
    $('#new_group_creating').addClass('hidden');
    $('#new_group_error').removeClass('hidden');
    $('#new_group_error_message').text(message ? message : 'something went wrong');
}

function fetchHtmlEntry(url, targetElement) {
    $.ajax({
        url: url,
        method: 'GET',
        success: function(response) {
            var element = $(response);
            element.hide();
            targetElement.prepend(element);
            $('#new_group_creating').addClass('hidden');
            $('#add_group_modal').modal('hide');
            element.fadeIn('slow');
        },
        error: function(xhr, ajaxOptions, thrownError) {
            showError(thrownError + ' (requesting entry HTML, group probably added though! - reload page to find out)');
        }
    });
}

function createGroup(form) {
    var editorForm = $(form);

    $('#new_group_error').addClass('hidden');

    if(!$('#new_group_name').val().length) {
        $('#new_group_name_group').addClass('has-error');
        $('#new_group_name_group .help-block').removeClass('hidden');
        return false;
    }

    $('#new_group_creating').removeClass('hidden');
    $('#new_group_name_group').removeClass('has-error');
    $('#new_group_name_group .help-block').addClass('hidden');

    var data = editorForm.serialize();
    if(editorForm.data('create-parent')) {
        var postUrl = editorForm.data('post-parent-group-url');
        var rowUrl = editorForm.data('parent-group-row-url');
        var targetElement = $('#job_group_list');
    } else {
        var postUrl = editorForm.data('post-job-group-url');
        var rowUrl = editorForm.data('job-group-row-url');
        var parentId = editorForm.data('parent-id');
        if(parentId !== 'none') {
            var targetElement = $('#parent_group_' + parentId).find('ul');
            data += '&parent_id=' + parentId;
        } else {
            var targetElement = $('#job_group_list');
        }
    }

    $.ajax({
        url: postUrl,
        method: 'POST',
        data: data,
        success: function(response) {
            if(!response) {
                showError('Server returned no response');
                return;
            }
            var id = response.id;
            if(!id) {
                showError('Server returned no ID');
                return;
            }
            fetchHtmlEntry(rowUrl + response.id, targetElement);
        },
        error: function(xhr, ajaxOptions, thrownError) {
            showError(thrownError);
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
    if(dragData) {
        var parentLiElement = parentDivElement.parentElement;
        var isTopLevel = parentLiElement.parentElement.id === 'job_group_list';

        if(dragData.isParent && !isTopLevel) {
            return;
        }

        event.preventDefault();
        removeAllDropIndicators();
        $(parentLiElement).addClass('dragover');
    }
}

function checkParentDrop(event, parentDivElement, enforceParentDrop, noChildDrop) {
    if(dragData) {
        if(noChildDrop && dragData.isParent) {
            return;
        }

        event.preventDefault();
        event.stopPropagation();

        removeAllDropIndicators();
        if((dragData.enforceParentDrop = enforceParentDrop) || dragData.isParent) {
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
    if(dragData) {
        dragData.liElement.hide();

        if(dragData.isParent || dragData.enforceParentDrop) {
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
    if(dragData) {
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
    // wipe scheduled queries (for still uncommited changes new queries will be added)
    ajaxQueries = [];

    // to avoid flickering, show the panel a litle bit delayed
    showPanelTimeout = setTimeout(function() {
        $('#reorganize_groups_panel').removeClass('hidden');
    }, 500);
    $('#reorganize_groups_progress').removeClass('hidden');
    $('#reorganize_groups_error').addClass('hidden');

    var jobGroupList = $('#job_group_list');
    var updateParentGroupUrl = jobGroupList.data('put-parent-group-url');
    var updateJobGroupUrl = jobGroupList.data('put-job-group-url');

    // event handlers for AJAX queries
    var handleError = function(xhr, ajaxOptions, thrownError) {
        $('#reorganize_groups_panel').removeClass('hidden');
        $('#reorganize_groups_error').removeClass('hidden');
        $('#reorganize_groups_progress').addClass('hidden');
        $('#reorganize_groups_error_message').text(thrownError ? thrownError : 'something went wrong');
        $('html, body').animate({scrollTop: 0}, 1000);
    };

    var handleSuccess = function(response, groupLi, index, parentId) {
        if(!response) {
            handleError(undefined, undefined, 'Server returned nothing');
            return;
        }

        if(!response.nothingToDo) {
            var id = response.id;
            if(!id) {
                handleError(undefined, undefined, 'Server returned no ID');
                return;
            }

            // update initial value (to avoid queries for already commited changes)
            groupLi.data('initial-index', index);
            if(parentId) {
                groupLi.data('initial-parent', parentId);
            }
        }

        if(ajaxQueries.length) {
            // do next query
            $.ajax(ajaxQueries.shift());
        } else {
            // all queries done
            if(showPanelTimeout) {
                clearTimeout(showPanelTimeout);
                showPanelTimeout = undefined;
            }
            $('#reorganize_groups_progress').addClass('hidden');
            $('#reorganize_groups_error').addClass('hidden');
            $('#reorganize_groups_panel').addClass('hidden');
        }
    };

    // determine what changed to make required AJAX queries
    jobGroupList.children('li').each(function(groupIndex) {
        var groupLi = $(this);

        if(this.id.indexOf('job_group_') === 0) {
            var isParent = false;
            var groupId = parseInt(this.id.substr(10));
            var updateGroupUrl = updateJobGroupUrl;
        } else if(this.id.indexOf('parent_group_') === 0) {
            var isParent = true;
            var groupId = parseInt(this.id.substr(13));
            var updateGroupUrl = updateParentGroupUrl;
        }
        var parentId = groupLi.data('initial-parent');

        if(groupIndex != groupLi.data('initial-index') || parentId !== 'none') {
            // index of parent group changed -> update sort order
            ajaxQueries.push({
                url: updateGroupUrl + groupId,
                method: 'PUT',
                data: {
                    sort_order: groupIndex,
                    parent_id: 'none'
                },
                success: function(response) {
                    handleSuccess(response, groupLi, groupIndex);
                },
                error: handleError
            });
        }

        if(isParent) {
            groupLi.find('ul').children('li').each(function(childGroupIndex) {
                var jobGroupLi = $(this);
                var jobGroupId = parseInt(this.id.substr(10));

                if(childGroupIndex != jobGroupLi.data('initial-index')
                    || groupId != jobGroupLi.data('initial-parent')) {
                    // index or parent of job group changed -> update parent and sort order
                    ajaxQueries.push({
                        url: updateJobGroupUrl + jobGroupId,
                        method: 'PUT',
                        data: {
                            sort_order: childGroupIndex,
                            parent_id: groupId
                        },
                        success: function(response) {
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
