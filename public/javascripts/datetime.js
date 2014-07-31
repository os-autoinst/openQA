document.observe('dom:loaded', function() {

  $$('time').each(function(element){ element.innerHTML = new Date(element.innerHTML.strip().replace(' ','T')+'Z').toLocaleString(); });

});
