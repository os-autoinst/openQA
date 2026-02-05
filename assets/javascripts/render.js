// jshint esversion: 9

function createElement(tag, content = [], attrs = {}, options = {}) {
  const elem = document.createElement(tag);

  for (const [key, value] of Object.entries(attrs)) {
    if (value !== undefined) {
      elem.setAttribute(key, value);
    }
  }

  elem.append(...content);
  if (options.preWrap) {
    elem.style.whiteSpace = 'pre-wrap';
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
        class: 'flag fa-solid fa-plug',
        title: 'Fatal: testsuite is aborted if this test fails'
      })
    );
  } else if (module.flags.indexOf('important') < 0) {
    flags.push(
      E('i', [], {
        class: 'flag fa-solid fa-minus',
        title: 'Ignore failure: failure or soft failure of this test does not impact overall job result'
      })
    );
  }
  if (module.flags.indexOf('milestone') >= 0) {
    flags.push(
      E('i', [], {
        class: 'flag fa-solid fa-anchor',
        title: 'Milestone: snapshot the state after this test for restoring'
      })
    );
  }
  if (module.flags.indexOf('always_rollback') >= 0) {
    flags.push(
      E('i', [], {
        class: 'flag fa-solid fa-rotate-left',
        title: 'Always rollback: revert to the last milestone snapshot even if test module is successful'
      })
    );
  }
  if (module.flags.indexOf('always_run') >= 0) {
    flags.push(
      E('i', [], {
        class: 'flag fa fa-play',
        title: 'Always run: test module is executed even if a previous test module failed with fatal'
      })
    );
  }

  const srcUrl = renderTemplate(snippets.src_url, {MODULE: encodeURIComponent(module.name)});
  const srcElement = srcUrl ? E('a', [module.name], {href: srcUrl}) : E('span', [module.name]);
  const component = E('td', [E('div', [srcElement]), E('div', flags, {class: 'flags'})], {class: 'component'});

  const result = E('td', [module.result], {class: 'result ' + moduleResultCSS(module.result)});
  const showPreviewForLink = function () {
    if (typeof jQuery !== 'undefined') {
      setCurrentPreview($(this.parentElement)); // show the preview when clicking on step links
    }
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
    const textData = typeof step.text_data === 'string' ? step.text_data : '';
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
        let shortText = textData.replace(/.*# Result:\n*/s, '');
        // jshint ignore:end
        if (shortText.length > previewLimit) {
          shortText = shortText.substr(0, previewLimit) + '…';
        }
        box.push(E('span', [shortText], {class: 'resborder ' + resborder}));
      } else {
        box.push(E('span', [step.title ? step.title : 'Text'], {class: 'resborder ' + resborder}));
      }
    } else {
      const content = step.title || E('i', [], {class: 'fa-solid fa-circle-question'});
      box.push(E('span', [content], {class: 'resborder ' + resborder}));
    }
    if (step.text && title !== 'Soft Failed') {
      const stepActions = E('span', [], {class: 'step_actions', style: 'float: right'});
      stepActions.innerHTML = renderTemplate(snippets.bug_actions, {MODULE: module.name, STEP: step.num});
      const textresult = E('pre', [textData]);
      let html = stepActions.outerHTML;
      html += textresult.outerHTML;
      const txt = escape(html);
      const link = E('a', box, {
        class: 'no_hover' + (title === 'wait_serial' ? ' serial-result-preview' : ''),
        'data-text': txt,
        title: title,
        href: href
      });
      link.onclick = showPreviewForLink;
      stepnodes.push(E('div', [E('div', [], {class: 'fa-solid fa-caret-up'}), link], {class: 'links_a'}));
    } else {
      const link = E('a', box, {
        class: 'no_hover',
        'data-url': url,
        title: title,
        href: href
      });
      link.onclick = showPreviewForLink;
      stepnodes.push(E('div', [E('div', [], {class: 'fa-solid fa-caret-up'}), link], {class: 'links_a'}));
    }
    stepnodes.push(' ');
    if (typeof textData === 'string' && textData.startsWith('Unable to read ')) {
      // signal updateTestStatus() that there's still something missing here
      result.classList.add('textdatamissing');
      testStatus.textDataMissing = true;
    }
  }

  const links = E('td', stepnodes, {class: 'links'});
  return E('tr', [component, result, links], {id: rowid});
}

// Default batch size for chunked rendering to balance responsiveness and overhead
const renderBatchSizeMeta = document.querySelector('meta[name="render-batch-size"]');
const DEFAULT_BATCH_SIZE = renderBatchSizeMeta ? parseInt(renderBatchSizeMeta.content, 10) : 50;

/**
 * Process an array of items in batches using requestAnimationFrame for cooperative multitasking.
 * This prevents blocking the UI thread during long-running operations.
 *
 * @param {Array} items - Array of items to process
 * @param {Function} processor - Function called for each item with (item, index) as arguments
 * @param {Object} options - Processing options
 * @param {number} [options.batchSize=50] - Number of items to process per frame
 * @param {Function} [options.shouldContinue=() => true] - Callback returning boolean to control interruption
 * @returns {Promise<boolean>} Promise resolving to true if completed, false if interrupted
 * @throws {Error} If processor throws an error during execution
 */
function batchProcess(items, processor, options = {}) {
  const {batchSize = DEFAULT_BATCH_SIZE, shouldContinue = () => true} = options;
  let currentIndex = 0;

  return new Promise((resolve, reject) => {
    function processNextBatch() {
      if (!shouldContinue()) {
        resolve(false); // Interrupted
        return;
      }

      const end = Math.min(currentIndex + batchSize, items.length);
      try {
        for (; currentIndex < end; currentIndex++) {
          processor(items[currentIndex], currentIndex);
        }
      } catch (err) {
        reject(err);
        return;
      }

      if (currentIndex < items.length) {
        requestAnimationFrame(processNextBatch);
      } else {
        resolve(true); // Completed
      }
    }
    processNextBatch();
  });
}

async function renderModuleTable(container, response, shouldContinue = () => true) {
  container.innerHTML = response.snippets.header;

  const E = createElement;
  const isFinal = testStatus.state === 'done' || testStatus.state === 'cancelled';
  const showErrors = isFinal && Array.isArray(response.errors);
  const errors = showErrors ? response.errors.filter(e => !e.includes('No such file')) : [];
  if (errors.length > 0) {
    const liElements = errors.map(error => E('li', error));
    const ul = E('ul', liElements);
    addFlash('danger', E('div', ['Errors occurred when trying to load test results:', ul]));
  }

  if (response.modules === undefined || response.modules === null) {
    return Promise.resolve(true);
  }

  const thead = E('thead', [
    E('tr', [E('th', ['Test']), E('th', ['Result']), E('th', ['References'], {style: 'width: 100%'})])
  ]);
  const tbody = E('tbody');

  container.appendChild(E('table', [thead, tbody], {id: 'results', class: 'table table-striped'}));

  return batchProcess(
    response.modules,
    module => {
      if (module.category) {
        tbody.appendChild(
          E('tr', [E('td', [E('i', [], {class: 'fa-regular fa-folderpen'}), '\u00a0' + module.category], {colspan: 3})])
        );
      }
      tbody.appendChild(renderModuleRow(module, response.snippets));
    },
    {shouldContinue}
  );
}

function renderJobLink(jobId) {
  return createElement('a', [jobId], {href: `/tests/${jobId}`});
}

function renderMessages(messages) {
  return Array.isArray(messages) && messages.length > 1
    ? createElement(
        'ul',
        messages.map(m => createElement('li', m, {}, {preWrap: true}))
      )
    : createElement('span', [messages], {}, {preWrap: true});
}
