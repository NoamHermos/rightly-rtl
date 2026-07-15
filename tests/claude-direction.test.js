"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const payloadPath = path.join(__dirname, "..", "src", "claude", "claude-rtl-payload.js");
let payload = fs.readFileSync(payloadPath, "utf8");

const hookPoint = "    function detectElDir(el) {";
assert.ok(payload.includes(hookPoint), "detectElDir hook point is missing");
payload = payload.replace(
    hookPoint,
    "    window.__RT_AI_TEST_DETECT_TEXT_DIR__ = detectTextDir;\n" +
    "    window.__RT_AI_TEST_APPLY_BLOCK_DIR__ = applyBlockDir;\n\n" + hookPoint
);

const context = {
    window: {},
    document: {
        readyState: "loading",
        body: null,
        addEventListener: function () {}
    }
};

vm.runInNewContext(payload, context, { filename: payloadPath });
const detectTextDir = context.window.__RT_AI_TEST_DETECT_TEXT_DIR__;
const applyBlockDir = context.window.__RT_AI_TEST_APPLY_BLOCK_DIR__;

assert.equal(detectTextDir("Hello שלום"), "rtl");
assert.equal(detectTextDir("Claude - בדיקה"), "rtl");
assert.equal(detectTextDir("https://claude.ai כתוב בעברית"), "rtl");
assert.equal(detectTextDir("123 English ואז עברית"), "rtl");
assert.equal(detectTextDir("English only"), "ltr");
assert.equal(detectTextDir("مرحبا بالعالم"), "rtl");
assert.equal(detectTextDir(""), null);

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
applyBlockDir(block, detectTextDir("English ואז עברית"));
assert.equal(block.dir, "rtl");
assert.equal(block.getAttribute("data-rt-ai-claude-dir"), "rtl");
assert.equal(block.style.textAlign, "right");
assert.equal(block.style.unicodeBidi, "isolate");

const list = makeElement("UL");
const item = makeElement("LI");
item.closest = function () { return list; };
applyBlockDir(item, detectTextDir("Mongo מכיל מוצרים"));
assert.equal(item.style.listStylePosition, "outside");
assert.equal(list.dir, "rtl");

const restored = makeElement("P", { dir: "auto" });
restored.style.textAlign = "center";
applyBlockDir(restored, "rtl");
applyBlockDir(restored, null);
assert.equal(restored.getAttribute("dir"), "auto");
assert.equal(restored.style.textAlign, "center");

console.log("Claude RTL direction tests passed.");
