// jshint esversion: 6

function createElement(tag, content=[], attrs={}) {
    let elem = document.createElement(tag);

    for (let key in attrs) {
        elem.setAttribute(key, attrs[key]);
    }

    for (let idx in content) {
        let val = content[idx];

        if ((typeof val) === 'string') {
            val = document.createTextNode(val);
        }

        elem.appendChild(val);
    }

    return elem;
}

function renderTemplate(template, args={}) {
    for (let key in args) {
        template = template.split('$'+key+'$').join(args[key]);
        template = template.split(encodeURIComponent('$'+key+'$'));
        template = template.join(encodeURIComponent(args[key]));
    }

    return template;
}

function moduleResultCSS(result) {
    let resmap = {na: '', incomplete: '', softfailed: 'resultsoftfailed',
        passed: 'resultok', running: 'resultrunning'};

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
    let E = createElement;
    let rowid = 'module_' + module.name.replace(/[^a-z0-9_-]+/ig, '-');
    let flags = [];
    let stepnodes = [];

    if (module.execution_time) {
        flags.push(E('span', [module.execution_time]));
        flags.push('\u00a0');
    }

    if (module.flags.indexOf('fatal') >= 0) {
        flags.push(E('i', [], {
            'class': 'flag fa fa-plug',
            title: 'Fatal: testsuite is aborted if this test fails'
        }));
    } else if (module.flags.indexOf('important') < 0) {
        flags.push(E('i', [], {
            'class': 'flag fa fa-minus',
            title: 'Ignore failure: failure or soft failure of this test does not impact overall job result'
        }));
    }

    if (module.flags.indexOf('milestone') >= 0) {
        flags.push(E('i', [], {
            'class': 'flag fa fa-anchor',
            title: 'Milestone: snapshot the state after this test for restoring'
        }));
    }

    if (module.flags.indexOf('always_rollback') >= 0) {
        flags.push(E('i', [], {
            'class': 'flag fa fa-redo',
            title: 'Always rollback: revert to the last milestone snapshot even if test module is successful'
        }));
    }

    let src_url = renderTemplate(snippets.src_url,
        {MODULE: encodeURIComponent(module.name)});
    let component = E('td', [
        E('div', [E('a', [module.name], {href: src_url})]),
        E('div', flags, {'class': 'flags'})
    ], {'class': 'component'});

    let result = E('td', [module.result],
        {'class': 'result ' + moduleResultCSS(module.result)});

    for (let idx in module.details) {
        let step = module.details[idx];
        let title = step.display_title;
        let href = '#step/' + module.name + '/' + step.num;
        let tplargs = {MODULE: encodeURIComponent(module.name), STEP: step.num};
        let alt = '';

        if (step.name) {
            alt = step.name;
        }

        if (step.is_parser_text_result) {
            let elem = E('span', [], {'class': 'step_actions'});
            elem.innerHTML = renderTemplate(snippets.bug_actions,
                {MODULE: module.name, STEP: step.num});
            elem = E('span', [elem, step.text_data],
                {'class': 'resborder ' + step.resborder});
            elem = E('span', [elem], {title: title, 'data-href': href,
                'class': 'text-result', onclick: 'toggleTextPreview(this)'});
            stepnodes.push(E('div', [elem],
                {'class': 'links_a text-result-container'}));
            continue;
        }

        let url = renderTemplate(snippets.module_url, tplargs);
        let resborder = step.resborder;
        let box = [];

        if (step.screenshot) {
            let thumb;

            if (step.md5_dirname) {
                thumb = renderTemplate(snippets.md5thumb_url,
                    {DIRNAME: step.md5_dirname, BASENAME: step.md5_basename});
            } else {
                thumb = renderTemplate(snippets.thumbnail_url,
                    {FILENAME: step.screenshot});
            }

            if (step.properties &&
                step.properties.indexOf('workaround') >= 0) {
                resborder = 'resborder_softfailed';
            }

            box.push(E('img', [], {width: 60, height: 45, src: thumb, alt: alt,
                'class': 'resborder ' + resborder}));
        } else if (step.audio) {
            box.push(E('span', [], {alt: alt,
                'class': 'icon_audio resborder ' + resborder}));
        } else if (step.text && title === 'wait_serial') {
            box.push(E('span', [], {alt: alt,
                'class':'icon_terminal resborder '+resborder}));
        } else if (step.text) {
            box.push(E('span', [step.title ? step.title : 'Text'],
                {'class': 'resborder ' + resborder}));
        } else {
            let content = step.title;

            if (!content) {
                content = E('i', [], {'class': 'fas fa fa-question'});
            }

            box.push(E('span', [content], {'class': 'resborder '+resborder}));
        }

        stepnodes.push(E('div', [
            E('div', [], {'class': 'fa fa-caret-up'}),
            E('a', box, {'class': 'no_hover', title: title, href: href,
                'data-url': url})
        ], {'class': 'links_a'}));
        stepnodes.push(' ');
    }

    let links = E('td', stepnodes, {'class': 'links'});
    return E('tr', [component, result, links], {id: rowid});
}

function renderTestSummary(data) {
    var html = data.passed + "<i class='fa module_passed fa-star' title='modules passed'></i>";
    if (data.softfailed) {
        html += " " + data.softfailed + "<i class='fa module_softfailed fa-star-half' title='modules with warnings'></i>";
    }
    if (data.failed) {
        html += " " + data.failed + "<i class='far module_failed fa-star' title='modules failed'></i>";
    }
    if (data.none) {
        html += " " + data.none + "<i class='fa module_none fa-ban' title='modules skipped'></i>";
    }
    if (data.skipped) {
        html += " " + data.skipped + "<i class='fa module_skipped fa-angle-double-right' title='modules externally skipped'></i>";
    }

    return html;
}

function renderModuleTable(container, response) {
    container.innerHTML = response.snippets.header;

    if (response.modules === undefined || response.modules === null) {
        return;
    }

    let E = createElement;
    let thead = E('thead', [E('tr', [
        E('th', ['Test']),
        E('th', ['Result']),
        E('th', ['References'], {style: 'width: 100%'})
    ])]);
    let tbody = E('tbody');


    container.appendChild(E('div', '', {id: 'summary'}));
    container.appendChild(E('table', [thead, tbody],
        {id: 'results', 'class': 'table table-striped'}));

    let summary = {};

    for (let idx in response.modules) {
        let module = response.modules[idx];

        if (module.category) {
            tbody.appendChild(E('tr', [E('td', [
                E('i', [], {'class': 'fas fa-folder-open'}),
                '\u00a0' + module.category
            ], {colspan: 3})]));
        }

        tbody.appendChild(renderModuleRow(module, response.snippets));

        if (summary[module.result] === undefined)
            summary[module.result] = 1;
        else
            summary[module.result] ++;
    }

    $('#summary').html(renderTestSummary(summary, 'display'));
}
