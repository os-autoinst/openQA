// jshint esversion: 9

function createElement(tag, content = [], attrs = {}) {
  const elem = document.createElement(tag);

  for (const [key, value] of Object.entries(attrs)) {
    if (value !== undefined) {
      elem.setAttribute(key, value);
    }
  }

  for (const idx in content) {
    let val = content[idx];

    if (typeof val === 'string') {
      val = document.createTextNode(val);
    }

    elem.appendChild(val);
  }

  return elem;
}

function renderTemplate(template, args = {}) {
  if (!template) {
    return '';
  }
  for (const key in args) {
    const placeholder = '$' + key + '$';
    const value = args[key];
    template = template.split(placeholder).join(value);
    template = template.split(encodeURIComponent(placeholder)).join(encodeURIComponent(value));
  }
  return template;
}

function moduleResultCSS(result) {
  const resmap = {
    na: '',
    incomplete: '',
    softfailed: 'resultsoftfailed',
    passed: 'resultok',
    running: 'resultrunning'
  };

  if (!result) {
    return 'resultunknown';
  } else if (result.substr(0, 4) === 'fail') {
    return 'resultfailed';
  } else if (resmap[result] !== undefined) {
    return resmap[result];
  }

  return 'resultunknown';
}

function renderModuleRow(module, snippets) {
  const E = createElement;
  const rowid = 'module_' + module.name.replace(/[^a-z0-9_-]+/gi, '-');
  const flags = [];
  const stepnodes = [];

  if (module.execution_time) {
    flags.push(E('span', [module.execution_time]));
    flags.push('\u00a0');
  }
  if (module.flags.indexOf('fatal') >= 0) {
    flags.push(
      E('i', [], {
        class: 'flag fa fa-plug',
        title: 'Fatal: testsuite is aborted if this test fails'
      })
    );
  } else if (module.flags.indexOf('important') < 0) {
    flags.push(
      E('i', [], {
        class: 'flag fa fa-minus',
        title: 'Ignore failure: failure or soft failure of this test does not impact overall job result'
      })
    );
  }
  if (module.flags.indexOf('milestone') >= 0) {
    flags.push(
      E('i', [], {
        class: 'flag fa fa-anchor',
        title: 'Milestone: snapshot the state after this test for restoring'
      })
    );
  }
  if (module.flags.indexOf('always_rollback') >= 0) {
    flags.push(
      E('i', [], {
        class: 'flag fa fa-undo',
        title: 'Always rollback: revert to the last milestone snapshot even if test module is successful'
      })
    );
  }

  const srcUrl = renderTemplate(snippets.src_url, {MODULE: encodeURIComponent(module.name)});
  const srcElement = srcUrl ? E('a', [module.name], {href: srcUrl}) : E('span', [module.name]);
  const component = E('td', [E('div', [srcElement]), E('div', flags, {class: 'flags'})], {class: 'component'});

  const result = E('td', [module.result], {class: 'result ' + moduleResultCSS(module.result)});
  const showPreviewForLink = function () {
    setCurrentPreview($(this).parent()); // show the preview when clicking on step links
    return false;
  };

  for (const idx in module.details) {
    const step = module.details[idx];
    const title = step.display_title;
    const href = '#step/' + module.name + '/' + step.num;
    const tplargs = {MODULE: encodeURIComponent(module.name), STEP: step.num};
    const alt = step.name || '';

    if (step.is_parser_text_result) {
      const elements = [];
      const stepActions = E('span', [], {class: 'step_actions'});
      stepActions.innerHTML = renderTemplate(snippets.bug_actions, {MODULE: module.name, STEP: step.num});
      const stepFrame = E('span', [stepActions, step.text_data], {class: 'resborder ' + step.resborder});
      const textResult = E('span', [stepFrame], {
        title: step.is_parser_text_result ? title : undefined,
        'data-href': href,
        class: 'text-result',
        onclick: 'toggleTextPreview(this)'
      });
      elements.push(textResult);
      stepnodes.push(
        E('div', elements, {
          class: 'links_a external-result-container'
        })
      );
      continue;
    }

    const url = renderTemplate(snippets.module_url, tplargs);
    const box = [];
    let resborder = step.resborder;
    if (step.screenshot) {
      let thumb;
      if (step.md5_dirname) {
        thumb = renderTemplate(snippets.md5thumb_url, {DIRNAME: step.md5_dirname, BASENAME: step.md5_basename});
      } else {
        thumb = renderTemplate(snippets.thumbnail_url, {FILENAME: step.screenshot});
      }
      if (step.properties && step.properties.indexOf('workaround') >= 0) {
        resborder = 'resborder_softfailed';
      }
      box.push(
        E('img', [], {
          width: 60,
          height: 45,
          src: thumb,
          alt: alt,
          class: 'resborder ' + resborder
        })
      );
    } else if (step.audio) {
      box.push(
        E('span', [], {
          alt: alt,
          class: 'icon_audio resborder ' + resborder
        })
      );
    } else if (step.text) {
      if (title === 'wait_serial') {
        const previewLimit = 120;
        // jshint ignore:start
        let shortText = step.text_data.replace(/.*# Result:\n?/s, '');
        // jshint ignore:end
        if (shortText.length > previewLimit) {
          shortText = shortText.substr(0, previewLimit) + '…';
        }
        box.push(E('span', [shortText], {class: 'resborder ' + resborder}));
      } else {
        box.push(E('span', [step.title ? step.title : 'Text'], {class: 'resborder ' + resborder}));
      }
    } else {
      const content = step.title || E('i', [], {class: 'fa fa fa-question'});
      box.push(E('span', [content], {class: 'resborder ' + resborder}));
    }
    if (step.text && title !== 'Soft Failed') {
      const stepActions = E('span', [], {class: 'step_actions', style: 'float: right'});
      stepActions.innerHTML = renderTemplate(snippets.bug_actions, {MODULE: module.name, STEP: step.num});
      const textresult = E('pre', [step.text_data]);
      var html = stepActions.outerHTML;
      html += textresult.outerHTML;
      const txt = escape(html);
      const link = E('a', box, {
        class: 'no_hover' + (title === 'wait_serial' ? ' serial-result-preview' : ''),
        'data-text': txt,
        title: title,
        href: href
      });
      link.onclick = showPreviewForLink;
      stepnodes.push(E('div', [E('div', [], {class: 'fa fa-caret-up'}), link], {class: 'links_a'}));
    } else {
      const link = E('a', box, {
        class: 'no_hover',
        'data-url': url,
        title: title,
        href: href
      });
      link.onclick = showPreviewForLink;
      stepnodes.push(E('div', [E('div', [], {class: 'fa fa-caret-up'}), link], {class: 'links_a'}));
    }
    stepnodes.push(' ');
  }

  const links = E('td', stepnodes, {class: 'links'});
  return E('tr', [component, result, links], {id: rowid});
}

function renderModuleTable(container, response) {
  container.innerHTML = response.snippets.header;

  if (response.modules === undefined || response.modules === null) {
    return;
  }

  const E = createElement;
  const thead = E('thead', [
    E('tr', [E('th', ['Test']), E('th', ['Result']), E('th', ['References'], {style: 'width: 100%'})])
  ]);
  const tbody = E('tbody');

  container.appendChild(E('table', [thead, tbody], {id: 'results', class: 'table table-striped'}));

  for (const idx in response.modules) {
    const module = response.modules[idx];

    if (module.category) {
      tbody.appendChild(
        E('tr', [E('td', [E('i', [], {class: 'fa fa-folder-open'}), '\u00a0' + module.category], {colspan: 3})])
      );
    }

    tbody.appendChild(renderModuleRow(module, response.snippets));
  }
}
