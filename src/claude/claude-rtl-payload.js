// ===========================================================================
// Rightly for Claude - Smart RTL Detection & Alignment
//
// Runs from Claude Desktop's main-view preload. It fixes Hebrew/Arabic in the
// remote claude.ai conversation surface while leaving the desktop shell,
// navigation, menus, toolbars, and code blocks in their original direction.
// ===========================================================================

// --- RT-AI CLAUDE RTL PATCH START ---
;(function () {
    "use strict";

    if (typeof window === "undefined" || typeof document === "undefined") return;
    if (window.__RT_AI_CLAUDE_RTL_PATCH__) return;
    window.__RT_AI_CLAUDE_RTL_PATCH__ = true;
    try { console.info("[RT-AI Claude RTL] content script active"); } catch (_) { }

    var INPUT_SEL = ".ProseMirror, [contenteditable=\"true\"], textarea, input[type=\"text\"], input:not([type])";
    var CODE_SEL = "pre, code, .cm-editor, .monaco-editor, .shiki, .hljs, [data-language]";
    var TEXT_SEL = "p, li, h1, h2, h3, h4, h5, h6, blockquote, td, th";
    var TABLE_SEL = "table";
    var APP_CHROME_SEL = "nav, aside, [role=\"navigation\"], [role=\"menu\"], [role=\"menubar\"], [role=\"toolbar\"], [data-rt-ai-claude-ignore]";
    var MANAGED_DIR_ATTR = "data-rt-ai-claude-dir";
    var TABLE_WRAPPER_ATTR = "data-rt-ai-claude-table-wrapper";
    var originalDirectionStates = new WeakMap();
    var tableAlignmentTargets = new WeakMap();

    // Direction detection ----------------------------------------------------
    function isRTLChar(ch) {
        var code = ch.charCodeAt(0);
        return (code >= 0x0590 && code <= 0x05ff) ||
            (code >= 0x0600 && code <= 0x06ff) ||
            (code >= 0x0750 && code <= 0x077f) ||
            (code >= 0x08a0 && code <= 0x08ff) ||
            (code >= 0xfb1d && code <= 0xfdff) ||
            (code >= 0xfe70 && code <= 0xfeff);
    }

    function hasRTL(text) {
        if (!text) return false;
        for (var i = 0; i < text.length; i++) {
            if (isRTLChar(text[i])) return true;
        }
        return false;
    }

    function isHebrewLetter(ch) {
        var code = ch.charCodeAt(0);
        return (code >= 0x05d0 && code <= 0x05ea) ||
            (code >= 0x05ef && code <= 0x05f2) ||
            (code >= 0xfb1d && code <= 0xfb4f);
    }

    function hasHebrew(text) {
        if (!text) return false;
        for (var i = 0; i < text.length; i++) {
            if (isHebrewLetter(text[i])) return true;
        }
        return false;
    }

    function firstStrong(text) {
        if (!text) return null;
        for (var i = 0; i < text.length; i++) {
            if (isRTLChar(text[i])) return "rtl";
            if (/[A-Za-z]/.test(text[i])) return "ltr";
        }
        return null;
    }

    function textWithoutCode(el) {
        var out = "";
        var nodes = el.childNodes || [];
        for (var i = 0; i < nodes.length; i++) {
            var node = nodes[i];
            if (node.nodeType === 3) {
                out += node.textContent || "";
            } else if (node.nodeType === 1 && !node.matches(CODE_SEL)) {
                out += textWithoutCode(node);
            }
        }
        return out;
    }

    function stripLeadingLTR(text) {
        return String(text || "")
            .replace(/^[\s]*(?:[\w.-]+\.[A-Za-z]{1,8})\s*/g, "")
            .replace(/https?:\/\/\S+/g, "")
            .replace(/[\w.-]+[\/\\][\w.\/\\-]+/g, "")
            .replace(/`[^`]+`/g, "")
            .replace(/^[\s\d()[\]{}.,:;'\"!?@#$%^&*_+=|<>\/-]+/g, "");
    }

    function detectTextDir(text) {
        if (!text || !String(text).trim()) return null;
        // This is the key rule: Hebrew anywhere wins, even when an English
        // word, URL, number, or inline-code token appears first.
        if (hasHebrew(text)) return "rtl";
        var dir = firstStrong(text);
        if (dir === "rtl") return "rtl";
        if (!hasRTL(text)) return "ltr";
        dir = firstStrong(stripLeadingLTR(text));
        return dir === "rtl" ? "rtl" : "ltr";
    }

    function detectElDir(el) {
        var full = el.textContent || "";
        if (!hasRTL(full)) return null;
        return detectTextDir(textWithoutCode(el)) === "rtl" ? "rtl" : null;
    }

    function qsa(root, selector) {
        var base = root && root.querySelectorAll ? root : document;
        var els = Array.prototype.slice.call(base.querySelectorAll(selector));
        if (root && root.matches && root.matches(selector)) els.unshift(root);
        return els;
    }

    function qsaWithClosest(root, selector) {
        var els = qsa(root, selector);
        var closest = root && root.closest ? root.closest(selector) : null;
        if (closest && els.indexOf(closest) === -1) els.unshift(closest);
        return els;
    }

    function isInsideCode(el) {
        return !!(el && el.closest && el.closest(CODE_SEL));
    }

    function isInsideInput(el) {
        return !!(el && el.closest && el.closest(INPUT_SEL));
    }

    function isInsideAppChrome(el) {
        return !!(el && el.closest && el.closest(APP_CHROME_SEL));
    }

    // Managed DOM state ------------------------------------------------------
    function rememberDirectionState(el) {
        if (originalDirectionStates.has(el)) return;
        originalDirectionStates.set(el, {
            hadDir: el.hasAttribute("dir"),
            dir: el.getAttribute("dir"),
            direction: el.style.direction,
            textAlign: el.style.textAlign,
            unicodeBidi: el.style.unicodeBidi,
            listStylePosition: el.style.listStylePosition
        });
    }

    function setManagedDirection(el, dir, textAlign) {
        rememberDirectionState(el);
        el.setAttribute(MANAGED_DIR_ATTR, dir);
        el.dir = dir;
        el.style.direction = dir;
        el.style.textAlign = textAlign;
        el.style.unicodeBidi = "isolate";
    }

    function restoreManagedDirection(el) {
        if (!el.hasAttribute(MANAGED_DIR_ATTR)) return;
        var state = originalDirectionStates.get(el);
        el.removeAttribute(MANAGED_DIR_ATTR);
        if (!state) {
            el.removeAttribute("dir");
            el.style.direction = "";
            el.style.textAlign = "";
            el.style.unicodeBidi = "";
            el.style.listStylePosition = "";
            return;
        }
        if (state.hadDir) el.setAttribute("dir", state.dir);
        else el.removeAttribute("dir");
        el.style.direction = state.direction;
        el.style.textAlign = state.textAlign;
        el.style.unicodeBidi = state.unicodeBidi;
        el.style.listStylePosition = state.listStylePosition;
        originalDirectionStates.delete(el);
    }

    function forceCodeLTR(root) {
        qsa(root, CODE_SEL).forEach(function (el) {
            el.dir = "ltr";
            el.style.direction = "ltr";
            el.style.textAlign = "left";
            el.style.unicodeBidi = el.tagName === "CODE" ? "isolate" : "embed";
        });
    }

    function applyBlockDir(el, dir) {
        if (dir === "rtl") {
            setManagedDirection(el, "rtl", "right");
            if (el.tagName === "LI") {
                el.style.listStylePosition = "outside";
                var list = el.closest("ul, ol");
                if (list) setManagedDirection(list, "rtl", "right");
            }
        } else restoreManagedDirection(el);
    }

    function processText(root) {
        qsaWithClosest(root, TEXT_SEL).forEach(function (el) {
            if (isInsideInput(el) || isInsideCode(el) || isInsideAppChrome(el)) return;
            applyBlockDir(el, detectElDir(el));
        });

        qsaWithClosest(root, "ul, ol").forEach(function (el) {
            if (isInsideInput(el) || isInsideCode(el) || isInsideAppChrome(el)) return;
            applyBlockDir(el, detectElDir(el));
        });
    }

    // Tables -----------------------------------------------------------------
    function renderedWidth(el) {
        if (!el) return 0;
        if (el.getBoundingClientRect) {
            var rect = el.getBoundingClientRect();
            if (rect && rect.width) return rect.width;
        }
        return el.offsetWidth || el.clientWidth || 0;
    }

    function findTableAlignmentTarget(table) {
        var item = table;
        for (var depth = 0; depth < 8; depth++) {
            var parent = item.parentElement;
            if (!parent || parent === document.body || isInsideAppChrome(parent)) break;
            var itemWidth = renderedWidth(item);
            var parentWidth = renderedWidth(parent);
            if (itemWidth > 0 && parentWidth > itemWidth + 8) return item;
            item = parent;
        }
        return table;
    }

    function clearTableAlignmentTarget(table) {
        var target = tableAlignmentTargets.get(table);
        if (!target) return;
        target.removeAttribute(TABLE_WRAPPER_ATTR);
        if (target !== table) restoreManagedDirection(target);
        tableAlignmentTargets.delete(table);
    }

    function processTables(root) {
        qsaWithClosest(root, TABLE_SEL).forEach(function (table) {
            if (isInsideInput(table) || isInsideCode(table) || isInsideAppChrome(table)) return;
            var dir = detectElDir(table);
            applyBlockDir(table, dir);

            if (dir !== "rtl") {
                clearTableAlignmentTarget(table);
                return;
            }

            var target = findTableAlignmentTarget(table);
            var previousTarget = tableAlignmentTargets.get(table);
            if (previousTarget && previousTarget !== target) {
                previousTarget.removeAttribute(TABLE_WRAPPER_ATTR);
                if (previousTarget !== table) restoreManagedDirection(previousTarget);
            }
            if (target !== table) setManagedDirection(target, "rtl", "right");
            target.setAttribute(TABLE_WRAPPER_ATTR, "rtl");
            tableAlignmentTargets.set(table, target);
        });
    }

    function readInputText(el) {
        if ("value" in el) return el.value || "";
        return el.textContent || el.innerText || "";
    }

    function processInputElement(el) {
        if (isInsideAppChrome(el)) {
            restoreManagedDirection(el);
            return;
        }
        var dir = detectTextDir(readInputText(el));
        if (dir === "rtl") setManagedDirection(el, "rtl", "right");
        else if (dir === "ltr") setManagedDirection(el, "ltr", "left");
        else restoreManagedDirection(el);
    }

    function processInputs(root) {
        qsa(root, INPUT_SEL).forEach(processInputElement);
    }

    // Styling and lifecycle --------------------------------------------------
    function processAll(root) {
        var base = root || document.body || document;
        processTables(base);
        processText(base);
        processInputs(base);
        forceCodeLTR(base);
    }

    function injectStyles() {
        if (document.getElementById("rt-ai-claude-rtl-styles")) return;
        var style = document.createElement("style");
        style.id = "rt-ai-claude-rtl-styles";
        style.textContent = [
            "[data-rt-ai-claude-dir=\"rtl\"]{direction:rtl!important;text-align:right!important;unicode-bidi:isolate!important}",
            "[data-rt-ai-claude-dir=\"ltr\"]{direction:ltr!important;text-align:left!important;unicode-bidi:isolate!important}",
            "ul[data-rt-ai-claude-dir=\"rtl\"],ol[data-rt-ai-claude-dir=\"rtl\"]{list-style-position:outside!important;padding-left:0!important;padding-right:1.5em!important}",
            "li[data-rt-ai-claude-dir=\"rtl\"]::marker{direction:rtl;unicode-bidi:isolate}",
            "table[data-rt-ai-claude-dir=\"rtl\"]{direction:rtl!important;text-align:right!important;display:table!important;width:max-content!important;min-width:0!important;max-width:100%!important;margin-left:auto!important;margin-right:auto!important;align-self:center!important;justify-self:center!important}",
            "[data-rt-ai-claude-table-wrapper=\"rtl\"]{direction:rtl!important;text-align:right!important;width:fit-content!important;max-width:100%!important;margin-left:auto!important;margin-right:auto!important;align-self:center!important;justify-self:center!important}",
            "table[data-rt-ai-claude-dir=\"rtl\"] th,table[data-rt-ai-claude-dir=\"rtl\"] td{text-align:right!important;unicode-bidi:isolate!important}",
            "pre,.cm-editor,.monaco-editor,.shiki,.hljs,[data-language]{direction:ltr!important;text-align:left!important;unicode-bidi:embed!important}",
            "code{direction:ltr!important;unicode-bidi:isolate!important}"
        ].join("\n");
        (document.head || document.documentElement).appendChild(style);
    }

    function schedule(root) {
        if (window.__RT_AI_CLAUDE_RTL_TIMER__) return;
        window.__RT_AI_CLAUDE_RTL_TIMER__ = window.setTimeout(function () {
            window.__RT_AI_CLAUDE_RTL_TIMER__ = null;
            processAll(root || document.body || document);
        }, 50);
    }

    function init() {
        if (!document.body) return;
        injectStyles();
        processAll(document.body);

        document.addEventListener("input", function (event) {
            var target = event.target;
            if (!target || !target.matches) return;
            if (target.matches(INPUT_SEL) || (target.closest && target.closest(INPUT_SEL))) {
                processInputElement(target.closest(INPUT_SEL) || target);
                schedule(document.body);
            }
        }, true);

        var observer = new MutationObserver(function (mutations) {
            var roots = [];
            for (var i = 0; i < mutations.length; i++) {
                var mutation = mutations[i];
                if (mutation.type === "characterData" && mutation.target.parentElement) {
                    roots.push(mutation.target.parentElement);
                }
                for (var j = 0; j < mutation.addedNodes.length; j++) {
                    var node = mutation.addedNodes[j];
                    if (node.nodeType === 1) roots.push(node);
                }
            }

            if (roots.length === 0) return;
            if (roots.length <= 30) {
                roots.forEach(processAll);
                processInputs(document);
            } else {
                schedule(document.body);
            }
        });

        observer.observe(document.body, { childList: true, subtree: true, characterData: true });
        console.info("[RT-AI Claude RTL] patch active");
    }

    if (document.readyState === "loading" || !document.body) {
        document.addEventListener("DOMContentLoaded", init, { once: true });
    } else {
        init();
    }
})()
// --- RT-AI CLAUDE RTL PATCH END ---
