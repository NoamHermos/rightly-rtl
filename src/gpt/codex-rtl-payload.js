// ===========================================================================
// Rightly for Codex - Smart RTL Detection & Alignment
//
// Adds automatic right-to-left support to OpenAI Codex Desktop on Windows.
// Detects Hebrew and Arabic text in the composer and streamed responses,
// aligns RTL content naturally, and keeps code blocks left-to-right.
//
// Part of the RT-AI tooling suite (https://rt-ai.co.il).
// ===========================================================================

// --- RT-AI CODEX RTL PATCH START ---
;(function () {
    "use strict";

    if (typeof window === "undefined" || typeof document === "undefined") return;
    if (window.__RT_AI_CODEX_RTL_PATCH__) return;
    window.__RT_AI_CODEX_RTL_PATCH__ = true;

    var INPUT_SEL = ".ProseMirror, [contenteditable=\"true\"], textarea, input[type=\"text\"], input:not([type])";
    var CODE_SEL = "pre, code, .cm-editor, .monaco-editor, .shiki, .hljs, [data-language]";
    var TEXT_SEL = "p, li, h1, h2, h3, h4, h5, h6, blockquote, td, th";
    var TABLE_SEL = "table";
    var APP_CHROME_SEL = "nav, aside, [role=\"navigation\"], [role=\"menu\"], [role=\"menubar\"], [role=\"toolbar\"]";
    var SIDEBAR_TITLE_SEL = "aside [data-thread-title=\"true\"]";
    var SIDEBAR_RTL_MARK = "\u200f";
    var SIDEBAR_MARK_ATTR = "data-rt-ai-sidebar-rtl";
    var MANAGED_DIR_ATTR = "data-rt-ai-dir";
    var TABLE_WRAPPER_ATTR = "data-rt-ai-table-wrapper";
    var BLOCK_SEL = "table, ul, ol, " + TEXT_SEL + ", " + INPUT_SEL;
    var MAX_MUTATION_NODES = 200;
    var PROCESS_BATCH_SIZE = 3;
    var originalDirectionStates = new WeakMap();
    var sidebarTitleStates = new WeakMap();
    var tableAlignmentTargets = new WeakMap();
    var pendingRoots = [];
    var pendingRootSet = new WeakSet();

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
            .replace(/^[\s\d()[\]{}.,:;'"!?@#$%^&*_+=|<>/-]+/g, "");
    }

    function detectTextDir(text) {
        if (!text || !String(text).trim()) return null;
        if (hasHebrew(text)) return "rtl";
        var dir = firstStrong(text);
        if (dir === "rtl") return "rtl";
        if (!hasRTL(text)) return "ltr";
        dir = firstStrong(stripLeadingLTR(text));
        return dir === "rtl" ? "rtl" : "ltr";
    }

    // Left sidebar -----------------------------------------------------------
    // Keep its layout LTR, but prefix mixed Hebrew titles with an invisible
    // RLM so the Unicode bidi algorithm orders the words correctly.
    function normalizeSidebarTitleText(text) {
        var clean = String(text || "").replace(/^\u200f+/, "");
        return hasHebrew(clean) ? SIDEBAR_RTL_MARK + clean : clean;
    }

    function processSidebarTitleElement(el) {
        var current = el.textContent || "";
        var next = normalizeSidebarTitleText(current);
        var isHebrew = hasHebrew(next);

        if (isHebrew && !sidebarTitleStates.has(el)) {
            sidebarTitleStates.set(el, {
                hadDir: el.hasAttribute("dir"),
                dir: el.getAttribute("dir"),
                textAlign: el.style.textAlign
            });
        }

        if (current !== next) {
            if (el.childNodes.length === 1 && el.firstChild && el.firstChild.nodeType === 3) {
                el.firstChild.nodeValue = next;
            } else {
                el.textContent = next;
            }
        }

        if (isHebrew) {
            el.setAttribute(SIDEBAR_MARK_ATTR, "true");
            el.setAttribute("dir", "auto");
            el.style.textAlign = "left";
            return;
        }

        if (!el.hasAttribute(SIDEBAR_MARK_ATTR)) return;
        el.removeAttribute(SIDEBAR_MARK_ATTR);
        var state = sidebarTitleStates.get(el);
        if (state) {
            if (state.hadDir) el.setAttribute("dir", state.dir);
            else el.removeAttribute("dir");
            el.style.textAlign = state.textAlign;
            sidebarTitleStates.delete(el);
        } else {
            el.removeAttribute("dir");
            el.style.textAlign = "";
        }
    }

    function processSidebarTitles(root) {
        if (root && root.nodeType === 3) {
            var parentTitle = root.parentElement && root.parentElement.closest &&
                root.parentElement.closest(SIDEBAR_TITLE_SEL);
            if (parentTitle) processSidebarTitleElement(parentTitle);
            return;
        }
        qsaWithClosest(root, SIDEBAR_TITLE_SEL).forEach(processSidebarTitleElement);
    }

    function detectElDir(el) {
        var full = el.textContent || "";
        if (!hasRTL(full)) return null;
        var noCode = textWithoutCode(el);
        return detectTextDir(noCode) === "rtl" ? "rtl" : null;
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
        if (dir === "rtl") {
            setManagedDirection(el, "rtl", "right");
        } else if (dir === "ltr") {
            setManagedDirection(el, "ltr", "left");
        } else restoreManagedDirection(el);
    }

    function processInputs(root) {
        qsa(root, INPUT_SEL).forEach(processInputElement);
    }

    // Styling ----------------------------------------------------------------
    function processAll(root) {
        var base = root || document.body || document;
        processSidebarTitles(base);
        processTables(base);
        processText(base);
        processInputs(base);
        forceCodeLTR(base);
    }

    function injectStyles() {
        if (document.getElementById("rt-ai-codex-rtl-styles")) return;
        var style = document.createElement("style");
        style.id = "rt-ai-codex-rtl-styles";
        style.textContent = [
            "[data-rt-ai-dir=\"rtl\"]{direction:rtl!important;text-align:right!important;unicode-bidi:isolate!important}",
            "[data-rt-ai-dir=\"ltr\"]{direction:ltr!important;text-align:left!important;unicode-bidi:isolate!important}",
            "ul[data-rt-ai-dir=\"rtl\"],ol[data-rt-ai-dir=\"rtl\"]{list-style-position:outside!important;padding-left:0!important;padding-right:1.5em!important}",
            "li[data-rt-ai-dir=\"rtl\"]::marker{direction:rtl;unicode-bidi:isolate}",
            "table[data-rt-ai-dir=\"rtl\"]{direction:rtl!important;text-align:right!important;display:table!important;width:max-content!important;min-width:0!important;max-width:100%!important;margin-left:auto!important;margin-right:auto!important;align-self:center!important;justify-self:center!important}",
            "[data-rt-ai-table-wrapper=\"rtl\"]{direction:rtl!important;text-align:right!important;width:fit-content!important;max-width:100%!important;margin-left:auto!important;margin-right:auto!important;align-self:center!important;justify-self:center!important}",
            "table[data-rt-ai-dir=\"rtl\"] th,table[data-rt-ai-dir=\"rtl\"] td{text-align:right!important;unicode-bidi:isolate!important}",
            "[data-thread-title=\"true\"][data-rt-ai-sidebar-rtl=\"true\"]{text-align:left!important}",
            "pre,.cm-editor,.monaco-editor,.shiki,.hljs,[data-language]{direction:ltr!important;text-align:left!important;unicode-bidi:embed!important}",
            "code{direction:ltr!important;unicode-bidi:isolate!important}"
        ].join("\n");
        document.head.appendChild(style);
    }

    // Incremental scheduling -------------------------------------------------
    // Large conversations are processed in idle-time batches. Streaming
    // mutations enqueue only the nearest affected block instead of rescanning.
    function requestWork(callback) {
        if (window.requestIdleCallback) {
            window.requestIdleCallback(callback, { timeout: 250 });
        } else {
            window.setTimeout(callback, 80);
        }
    }

    function flushQueue(deadline) {
        window.__RT_AI_CODEX_RTL_TIMER__ = null;
        var count = 0;
        while (pendingRoots.length && count < PROCESS_BATCH_SIZE) {
            if (count > 0 && deadline && deadline.timeRemaining && deadline.timeRemaining() < 4) break;
            var root = pendingRoots.shift();
            pendingRootSet.delete(root);
            if (root && root.isConnected !== false) processAll(root);
            count++;
        }
        if (pendingRoots.length) scheduleFlush();
    }

    function scheduleFlush() {
        if (window.__RT_AI_CODEX_RTL_TIMER__) return;
        window.__RT_AI_CODEX_RTL_TIMER__ = true;
        requestWork(flushQueue);
    }

    function enqueueRoot(root) {
        root = root || document.body || document;
        if (!root || pendingRootSet.has(root)) return;

        // Avoid processing overlapping containers repeatedly. Chat switches
        // often add a wrapper and hundreds of descendants in the same frame.
        if (root.nodeType === 1) {
            for (var i = pendingRoots.length - 1; i >= 0; i--) {
                var existing = pendingRoots[i];
                if (!existing || existing.nodeType !== 1) continue;
                if (existing.contains(root)) return;
                if (root.contains(existing)) {
                    pendingRoots.splice(i, 1);
                    pendingRootSet.delete(existing);
                }
            }
        }
        pendingRootSet.add(root);
        pendingRoots.push(root);
        scheduleFlush();
    }

    function enqueueWorkInSubtree(node) {
        var el = node && node.nodeType === 1 ? node : node && node.parentElement;
        if (!el || isInsideAppChrome(el) || isInsideCode(el)) return;

        var closest = el.closest && el.closest(BLOCK_SEL);
        if (closest && !isInsideAppChrome(closest) && !isInsideCode(closest)) {
            enqueueRoot(closest);
            return;
        }

        // Queue individual semantic blocks. This spreads a large conversation
        // across idle frames instead of blocking the renderer with one full scan.
        qsa(el, BLOCK_SEL).forEach(function (candidate) {
            if (!isInsideAppChrome(candidate) && !isInsideCode(candidate)) enqueueRoot(candidate);
        });
    }

    function enqueueExistingContent() {
        var contentRoot = document.querySelector("main, [role=\"main\"]") || document.body;
        if (contentRoot) enqueueWorkInSubtree(contentRoot);
        processSidebarTitles(document);
        processInputs(document);
    }

    function nearestWorkRoot(node) {
        var el = node && node.nodeType === 1 ? node : node && node.parentElement;
        if (!el || isInsideAppChrome(el) || isInsideCode(el)) return null;
        if (el.closest) {
            var table = el.closest("table");
            if (table) return table;
            var block = el.closest(BLOCK_SEL);
            if (block && !isInsideAppChrome(block) && !isInsideCode(block)) return block;
        }
        return el;
    }

    // Lifecycle --------------------------------------------------------------
    function init() {
        injectStyles();
        enqueueExistingContent();

        document.addEventListener("input", function (event) {
            var target = event.target;
            if (!target || !target.matches) return;
            if (target.matches(INPUT_SEL) || (target.closest && target.closest(INPUT_SEL))) {
                processInputElement(target.closest(INPUT_SEL) || target);
                enqueueRoot(target.closest(INPUT_SEL) || target);
            }
        }, true);

        var observer = new MutationObserver(function (mutations) {
            var handledNodes = 0;
            for (var i = 0; i < mutations.length; i++) {
                var mutation = mutations[i];
                if (mutation.type === "characterData" && mutation.target.parentElement) {
                    var sidebarTitle = mutation.target.parentElement.closest &&
                        mutation.target.parentElement.closest(SIDEBAR_TITLE_SEL);
                    if (sidebarTitle) {
                        processSidebarTitleElement(sidebarTitle);
                    } else {
                        var textRoot = nearestWorkRoot(mutation.target);
                        if (textRoot) enqueueRoot(textRoot);
                    }
                }
                for (var j = 0; j < mutation.addedNodes.length; j++) {
                    processSidebarTitles(mutation.addedNodes[j]);
                    enqueueWorkInSubtree(mutation.addedNodes[j]);
                    handledNodes++;
                    if (handledNodes >= MAX_MUTATION_NODES) break;
                }
                if (handledNodes >= MAX_MUTATION_NODES) {
                    enqueueExistingContent();
                    break;
                }
            }
        });

        observer.observe(document.body, { childList: true, subtree: true, characterData: true });
        console.info("[RT-AI Codex RTL] patch active");
    }

    if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", init, { once: true });
    } else {
        init();
    }
})()
// --- RT-AI CODEX RTL PATCH END ---
