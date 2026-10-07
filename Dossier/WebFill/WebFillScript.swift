import Foundation

/// The scripts Dossier runs on a web page, in their own content world, so the site's scripts can neither
/// see nor change them. They read the page's fields and write values into them; nothing else.
nonisolated enum WebFillScript {
    /// Shared helpers, defined before each script runs.
    private static let helpers = #"""
        const textOf = (el) => ((el && (el.innerText || el.textContent)) || '').replace(/\s+/g, ' ').trim();
        const norm = (s) => (s || '').toString().toLowerCase().replace(/[^a-z0-9]/g, '');
        const frames = () => {
            const docs = [document];
            document.querySelectorAll('iframe, frame').forEach((f) => { try { if (f.contentDocument) docs.push(f.contentDocument); } catch (e) {} });
            return docs;
        };
        const find = (token) => {
            for (const doc of frames()) {
                const found = doc.querySelectorAll('[data-dossier-id="' + token + '"]');
                if (found.length) return Array.from(found);
            }
            return [];
        };
        """#

    /// Reads every visible field: what it's called, which section it's in, and its choices. Each field
    /// gets a `data-dossier-id` so it can be filled later.
    static let scan = helpers + #"""
        let counter = window.__dossierCounter || 0;
        const labelFor = (el) => {
            let t = '';
            if (el.labels && el.labels.length) t = Array.from(el.labels).map(textOf).join(' ');
            const by = el.getAttribute('aria-labelledby');
            if (!t && by) t = by.split(/\s+/).map((id) => textOf(el.ownerDocument.getElementById(id))).join(' ');
            if (!t) t = el.getAttribute('aria-label') || el.getAttribute('title') || '';
            if (!t) {
                const cell = el.closest('td');
                if (cell && cell.previousElementSibling) t = textOf(cell.previousElementSibling);
            }
            let sibling = el.previousElementSibling;
            while (!t && sibling) { if (!sibling.matches('input,select,textarea')) t = textOf(sibling); sibling = sibling.previousElementSibling; }
            if (!t && el.parentElement) t = textOf(el.parentElement).slice(0, 120);
            return t.slice(0, 200);
        };
        const sectionFor = (el) => {
            const parts = [];
            const fieldset = el.closest('fieldset');
            if (fieldset) { const legend = fieldset.querySelector('legend'); if (legend) parts.push(textOf(legend)); }
            let node = el, depth = 0;
            while (node && depth < 10 && parts.length < 2) {
                let sibling = node.previousElementSibling, heading = '';
                while (sibling && !heading) {
                    if (/^H[1-5]$/.test(sibling.tagName) || sibling.matches('legend,[role=heading]')) heading = textOf(sibling);
                    else if (sibling.querySelector) { const h = sibling.querySelector('h1,h2,h3,h4,h5,[role=heading]'); if (h) heading = textOf(h); }
                    sibling = sibling.previousElementSibling;
                }
                if (heading && !parts.includes(heading)) parts.push(heading);
                if (heading) break;
                node = node.parentElement; depth += 1;
            }
            return parts.join(' — ').slice(0, 200);
        };
        const visible = (el) => {
            const r = el.getBoundingClientRect(), s = el.ownerDocument.defaultView.getComputedStyle(el);
            return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none';
        };
        const fields = [], groups = {};
        for (const doc of frames()) {
            doc.querySelectorAll('input, select, textarea').forEach((el) => {
                const type = el.tagName === 'SELECT' ? 'select' : el.tagName === 'TEXTAREA' ? 'textarea' : (el.type || 'text').toLowerCase();
                if (['hidden', 'submit', 'button', 'reset', 'image', 'password', 'checkbox', 'search', 'color', 'range'].includes(type)) return;
                if (el.disabled || el.readOnly) return;
                if (type === 'radio') {
                    const key = (el.form ? el.form.id || 'f' : 'd') + ':' + (el.name || el.id);
                    let group = groups[key];
                    if (!group) {
                        if (!el.dataset.dossierId) el.dataset.dossierId = 'r' + (++counter);
                        // The question: the group's own text ("Sex"), its legend, or what's before it.
                        const parent = el.parentElement;
                        const own = parent ? Array.from(parent.childNodes).filter((n) => n.nodeType === 3).map((n) => n.textContent).join(' ').replace(/\s+/g, ' ').trim() : '';
                        const group_ = el.closest('[role=radiogroup]');
                        const fieldset = el.closest('fieldset');
                        const legend = fieldset && fieldset.querySelectorAll('input[type=radio]').length <= 8 ? fieldset.querySelector('legend') : null;
                        const container = group_ || parent;
                        group = groups[key] = {
                            token: el.dataset.dossierId, type: 'radio', name: el.name || '', idAttr: el.id || '', autocomplete: '',
                            label: (group_ && group_.getAttribute('aria-label')) || own || (legend ? textOf(legend) : '') || labelFor(parent || el),
                            section: sectionFor(container || el), placeholder: '', maxLength: 0, options: [], value: '',
                        };
                        fields.push(group);
                    }
                    el.dataset.dossierId = group.token;
                    const optionLabel = (el.labels && el.labels.length) ? textOf(el.labels[0]) : el.value;
                    group.options.push(optionLabel);
                    if (el.checked) group.value = optionLabel;
                    return;
                }
                if (!visible(el)) return;
                if (!el.dataset.dossierId) el.dataset.dossierId = 'd' + (++counter);
                fields.push({
                    token: el.dataset.dossierId, type, name: el.name || '', idAttr: el.id || '',
                    autocomplete: el.getAttribute('autocomplete') || '', label: labelFor(el), section: sectionFor(el),
                    placeholder: el.placeholder || '', maxLength: el.maxLength > 0 ? el.maxLength : 0,
                    accept: type === 'file' ? (el.accept || '') : '',
                    options: type === 'select' ? Array.from(el.options).map((o) => o.text.trim()).slice(0, 300) : [],
                    value: type === 'select' ? (el.selectedIndex > 0 ? el.options[el.selectedIndex].text.trim() : '') : type === 'file' ? (el.files.length ? el.files[0].name : '') : (el.value || ''),
                });
            });
        }
        window.__dossierCounter = counter;
        return fields;
        """#

    /// Writes values. `items` is `[{token, candidates}]`: a dropdown or radio group takes the first
    /// candidate that matches one of its choices; a text field takes the first candidate. Values are set
    /// the way typing does, so sites built with React, Angular or Vue notice them.
    static let fill = helpers + #"""
        const setValue = (el, value) => {
            const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
            const setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
            el.focus();
            setter.call(el, value);
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
            el.blur();
        };
        const flash = (el) => {
            const before = el.style.outline;
            el.style.outline = '2px solid #4B45C6';
            setTimeout(() => { el.style.outline = before; }, 1600);
        };
        const results = {};
        for (const item of items) {
            const els = find(item.token);
            if (!els.length) { results[item.token] = false; continue; }
            const el = els[0];
            if (el.tagName === 'SELECT') {
                const options = Array.from(el.options);
                let index = -1;
                for (const c of item.candidates) {
                    const n = norm(c);
                    index = options.findIndex((o) => norm(o.text) === n || norm(o.value) === n);
                    if (index >= 0) break;
                }
                if (index < 0) {
                    for (const c of item.candidates) {
                        const n = norm(c);
                        if (n.length < 3) continue;
                        index = options.findIndex((o) => { const t = norm(o.text); return t.length >= 3 && (t.startsWith(n) || n.startsWith(t)); });
                        if (index >= 0) break;
                    }
                }
                if (index >= 0) {
                    el.selectedIndex = index;
                    el.dispatchEvent(new Event('input', { bubbles: true }));
                    el.dispatchEvent(new Event('change', { bubbles: true }));
                    flash(el);
                }
                results[item.token] = index >= 0;
            } else if (el.type === 'radio') {
                let done = false;
                for (const c of item.candidates) {
                    const n = norm(c);
                    const match = els.find((r) => norm(r.value) === n || (r.labels && r.labels.length && norm(textOf(r.labels[0])) === n));
                    if (match) { match.click(); flash(match.parentElement || match); done = true; break; }
                }
                results[item.token] = done;
            } else {
                setValue(el, item.candidates[0] || '');
                flash(el);
                results[item.token] = true;
            }
        }
        return results;
        """#

    /// Attaches a file to an upload field: `{token, name, type, base64}`.
    static let attach = helpers + #"""
        const els = find(token);
        if (!els.length) return false;
        const bytes = Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
        const file = new File([bytes], name, { type });
        const transfer = new DataTransfer();
        transfer.items.add(file);
        els[0].files = transfer.files;
        els[0].dispatchEvent(new Event('input', { bubbles: true }));
        els[0].dispatchEvent(new Event('change', { bubbles: true }));
        return true;
        """#
}
