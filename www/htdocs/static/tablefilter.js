var lastterm = '';
function tablefilter(entry, tableid)
{
  var r, c, row, cell;
  var term = entry.value.toLowerCase();
  if(term == lastterm) {
    return;
  }
  lastterm = term;
  var negate = false;
  var off = 0;

  if (term.length && term[0] == '!') {
    negate = true;
    off = 1;
  }

  if (term.length >= off && term.length-off && term.length < 3 + off) {
    if (entry.nextSibling.nodeType == 3) {
      entry.nextSibling.data = "";
    } else {
      entry.parentNode.removeChild(entry.nextSibling);
      entry.parentNode.appendChild(document.createTextNode(""));
    }
    return;
  }

  if (off) {
    term = term.substring(off);
  }

  if(term.length)
    console.log("searching for " + term);

  var ele;

  var table = document.getElementById(tableid);
  if (!table) {
	  console.log("table empty");
	  return;
  }
  {
    var parent = table.parentNode;
    var nextSibling = table.nextSibling; // this is a text node that survives the subsequent removal!
    parent.removeChild(table);
    var nfound = 0;
    var bugs = [];
    for (r = 1; row = table.rows[r]; r++) {
      var foundit = negate;
      if (!term.length) {
        foundit = true;
      } else {
        for (c = 1; cell = row.cells[c]; c++) {
          ele = cell.innerHTML.replace(/<[^>]+>/g,"");
          if (ele.toLowerCase().indexOf(term)>=0 ) {
            foundit = !negate;
            break;
          }
        }
      }
      if(foundit) {
	  row.style.display = '';
          if (nfound % 2)
            row.className = row.className.replace(/odd/, "even");
          else
            row.className = row.className.replace(/even/, "odd");
          ++nfound;
      } else {
	  row.style.display = 'none';
      }
    }
    parent.insertBefore(table, nextSibling);
  }
}
