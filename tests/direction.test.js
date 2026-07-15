"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const payloadPath = path.join(__dirname, "..", "src", "gpt", "codex-rtl-payload.js");
let payload = fs.readFileSync(payloadPath, "utf8");

const hookPoint = "    function detectElDir(el) {";
assert.ok(payload.includes(hookPoint), "detectElDir hook point is missing");
payload = payload.replace(
    hookPoint,
    "    window.__RT_AI_TEST_DETECT_TEXT_DIR__ = detectTextDir;\n" +
    "    window.__RT_AI_TEST_APPLY_BLOCK_DIR__ = applyBlockDir;\n" +
    "    window.__RT_AI_TEST_NORMALIZE_SIDEBAR_TITLE__ = normalizeSidebarTitleText;\n\n" + hookPoint
);

const context = {
    window: {},
    document: {
        readyState: "loading",
        addEventListener: function () {}
    }
};

vm.runInNewContext(payload, context, { filename: payloadPath });
const detectTextDir = context.window.__RT_AI_TEST_DETECT_TEXT_DIR__;
const applyBlockDir = context.window.__RT_AI_TEST_APPLY_BLOCK_DIR__;
const normalizeSidebarTitle = context.window.__RT_AI_TEST_NORMALIZE_SIDEBAR_TITLE__;

assert.equal(detectTextDir("Hello שלום"), "rtl");
assert.equal(detectTextDir("translate שלום please"), "rtl");
assert.equal(detectTextDir("Codex - בדיקה"), "rtl");
assert.equal(detectTextDir("Hello world"), "ltr");
assert.equal(detectTextDir("123 https://example.com"), "ltr");
assert.equal(detectTextDir("مرحبا بالعالم"), "rtl");
assert.equal(detectTextDir(""), null);
assert.equal(normalizeSidebarTitle("Hello שלום"), "\u200fHello שלום");
assert.equal(normalizeSidebarTitle("\u200fHello שלום"), "\u200fHello שלום");
assert.equal(normalizeSidebarTitle("Hello world"), "Hello world");

function makeElement(tagName, initialAttributes) {
    const attributes = new Map(Object.entries(initialAttributes || {}));
    return {
        tagName,
        style: {},
        hasAttribute: function (name) { return attributes.has(name); },
        getAttribute: function (name) { return attributes.has(name) ? attributes.get(name) : null; },
        setAttribute: function (name, value) { attributes.set(name, String(value)); },
        removeAttribute: function (name) { attributes.delete(name); }
    };
}

const block = makeElement("P");
applyBlockDir(block, detectTextDir("Hello שלום"));
assert.equal(block.dir, "rtl");
assert.equal(block.getAttribute("data-rt-ai-dir"), "rtl");
assert.equal(block.style.direction, "rtl");
assert.equal(block.style.textAlign, "right");
assert.equal(block.style.unicodeBidi, "isolate");

const list = makeElement("UL");
const listItem = makeElement("LI");
listItem.closest = function () { return list; };
applyBlockDir(listItem, detectTextDir("Mongo מכיל מוצרים"));
assert.equal(listItem.dir, "rtl");
assert.equal(listItem.style.unicodeBidi, "isolate");
assert.equal(listItem.style.listStylePosition, "outside");
assert.equal(list.dir, "rtl");
assert.equal(list.style.textAlign, "right");

const appManagedElement = makeElement("P", { dir: "rtl" });
appManagedElement.style.textAlign = "center";
applyBlockDir(appManagedElement, null);
assert.equal(appManagedElement.getAttribute("dir"), "rtl");
assert.equal(appManagedElement.style.textAlign, "center");

const restoredElement = makeElement("P", { dir: "auto" });
restoredElement.style.textAlign = "center";
applyBlockDir(restoredElement, "rtl");
applyBlockDir(restoredElement, null);
assert.equal(restoredElement.getAttribute("dir"), "auto");
assert.equal(restoredElement.style.textAlign, "center");
assert.equal(restoredElement.hasAttribute("data-rt-ai-dir"), false);

const table = makeElement("TABLE");
applyBlockDir(table, detectTextDir("Status מצב"));
assert.equal(table.dir, "rtl");
assert.equal(table.getAttribute("data-rt-ai-dir"), "rtl");
assert.equal(table.style.textAlign, "right");

console.log("RTL direction tests passed.");
