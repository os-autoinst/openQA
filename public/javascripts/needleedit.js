/*
 * This file contains all the functions for steps/edit - together with needleeditor.js
 */

function loadBackground() {
    nEditor.LoadBackground($(this).data('url'));
    $("#needleeditor_image").val($(this).data('image'));
    $("#needleeditor_imagedistri").val($(this).data('distri'));
    $("#needleeditor_imageversion").val($(this).data('version'));
}

function loadTagsAndName() {
    var tags = $(this).data('tags');
    $("#needleeditor_tags").find('input').each(function() {
	$(this).prop('checked', tags.indexOf($(this).val()) != -1);
    });
    $("#needleeditor_name").val($(this).data('suggested'));
    nEditor.LoadTags(tags);
}

function addTag() {
    var input = $('#newtag');
    var checkbox = nEditor.AddTag(input.val(), false);
    input.val('');
    checkbox.click();
    return false;
}

function doOverwrite()
{
    saveNeedleForm = document.forms['save_needle_form'];
    saveNeedleForm.submit();
    return true;
}

function setMargin() {
    console.log("SETMAR");
    console.log($('#margin'));
    console.log($('#margin').val());
    nEditor.setMargin($('#margin').val());
}

function setMatch() {
    nEditor.setMatch($('#match').val());
}

var nEditor;

function setup_needle_editor(imageurl, default_needle)
{
    nEditor = new NeedleEditor(imageurl, default_needle);

    $('.tag_checkbox').click(function() {
	nEditor.changeTag(this.value, this.checked);
    });

    $('#tag_add_button').click(addTag);
    $('#newtag').keypress(function() {
	if (event.keyCode==13)
	    return addTag();
    });
        
    $('#property_workaround').click(function() { nEditor.changeProperty(this.name, this.checked) });
    $('.area_selector').click(function() {
	nEditor.LoadAreas($(this).data('areas'));
    });

    $('.background_selector').click(loadBackground);
    $('.tags_selector').click(loadTagsAndName);

    var matchdialog = $( "#change-match-form" ).dialog({
	autoOpen: false,
	width: '40%',
	modal: true,
	buttons: {
	    "Set": setMatch,
	    Cancel: function() {
		matchdialog.dialog( "close" );
	    }
	},
	close: function() {
	    form[ 0 ].reset();
	}
    });
    
    form = matchdialog.find( "form" ).on( "submit", function( event ) {
	event.preventDefault();
	setMatch();
    });

    $('#change-match').button().on("click", function(event) {
	event.preventDefault();
	matchdialog.dialog("open");
    });

    var margindialog = $( "#change-margin-form" ).dialog({
	autoOpen: false,
	width: '40%',
	modal: true,
	buttons: {
	    "Set": setMargin,
	    Cancel: function() {
		margindialog.dialog( "close" );
	    }
	},
	close: function() {
	    form[ 0 ].reset();
	}
    });

    form = matchdialog.find( "form" ).on( "submit", function( event ) {
	event.preventDefault();
	setMargin();
     });
    
    $('#change-margin').button().on("click", function(event) {
	event.preventDefault();
	margindialog.dialog("open");
    });
}
