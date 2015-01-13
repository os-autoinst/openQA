function updateModuleslist(modlist, testname, testmodule) {
	var container = $("modlist_content");
	container.innerHTML = "";
	modlist.each(function(category) {
		var title = new Element("h2", {'class': "box-subheader modcategory"}).update(category.category);
		var ul = new Element("ul", {'class': "navigation modcategory" })
		category.modules.each(function(module) {
			var li = new Element("li");
			li.addClassName("mod-"+module.state);
			li.addClassName("result"+module.result);
			if (testmodule == module.name) { li.addClassName("selected"); }
			li.update(new Element("a", {href: "/tests/"+testname+"/modules/"+module.name+"/steps/1"}).update(module.name));
			ul.insert(li);
		});
		container.insert(title);
		container.insert(ul);
	});
}

function scrollModuleThumbnails() {
    var area = $("module-thumbnails");
    var current = $$('#module-thumbnails .current').first();

    if (!(area && current)) then: return;
    var offset = current.offsetLeft - area.offsetLeft;

    area.scrollLeft = 40 + offset - area.getWidth()/2;
}

document.observe('dom:loaded', function(evt) {
    var elements = $$('.chosen-select');
    for (var i = 0; i < elements.length; i++) {
        new Chosen(elements[i], {width: "98%"});
    }

    window.scrollModuleThumbnails();
});

//jquery alternative of the above
jQuery(function(evt) {
    $(".chosen-select").chosen({width: "98%"});;
});


function set_cookie(cname, cvalue, exdays) {
    var d = new Date();
    d.setTime(d.getTime()+(exdays*24*60*60*1000));
    var expires = "expires="+d.toGMTString();
    document.cookie = cname + "=" + cvalue + "; " + expires;
}

function get_cookie(cname) {
    var name = cname + "=";
    var ca = document.cookie.split(';');
    for(var i=0; i<ca.length; i++) {
        var c = ca[i].trim();
        if (c.indexOf(name)==0) return c.substring(name.length,c.length);
    }
    return false;
}
