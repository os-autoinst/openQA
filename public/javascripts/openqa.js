function updateModuleslist(modlist, testname, testmodule) {
    var container = $('<div/>');
    
    $.each(modlist, function(index, category) {
	var title = $('<h2 class="box-subheader modcategory">' + category.category + "</h2>");
	container.append(title);

	var ul = $('<ul class="navigation modcategory"></ul>');
	$.each(category.modules, function(index, module) {
	    var li = $('<li/>');
	    li.addClass("mod-"+module.state);
	    li.addClass("result"+module.result);
	    if (testmodule == module.name) { li.addClass("selected"); }
	    var link = $('<a>' + module.name + '</a>');
	    li.html(link);
	    link.attr('href', "/tests/"+testname+"/modules/"+module.name+"/steps/1");
	    ul.append(li);
	});
	
	container.append(ul);
    });
    $("#modlist_content").replaceWith(container);
}

function scrollModuleThumbnails() {
    var area = $("#module-thumbnails");
    var current = $('#module-thumbnails .current');

    if (!current)
	return;
    var offset = current.offset().left - area.offset().left;
    area.scrollLeft(40 + offset - area.width()/2);
}

jQuery(function(evt) {
    $(".chosen-select").chosen({width: "98%"});;
});

function setCookie(cname, cvalue, exdays) {
    var d = new Date();
    d.setTime(d.getTime()+(exdays*24*60*60*1000));
    var expires = "expires="+d.toGMTString();
    document.cookie = cname + "=" + cvalue + "; " + expires;
}

function getCookie(cname) {
    var name = cname + "=";
    var ca = document.cookie.split(';');
    for(var i=0; i<ca.length; i++) {
        var c = ca[i].trim();
        if (c.indexOf(name)==0) return c.substring(name.length,c.length);
    }
    return false;
}
