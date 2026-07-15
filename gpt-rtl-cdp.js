"use strict";

// Injects the Rightly renderer payload into the official GPT Work / Codex
// renderer through page-specific, loopback-only DevTools WebSockets. No
// application files are copied or modified.

const fs = require("node:fs");
const http = require("node:http");
const path = require("node:path");

function parseArgs(argv) {
    const result = {};
    for (let i = 2; i < argv.length; i += 2) {
        const key = argv[i].replace(/^--/, "");
        result[key] = argv[i + 1];
    }
    return result;
}

const args = parseArgs(process.argv);
const port = Number(args.port);
const payloadPath = args.payload;
const logPath = args.log;
const injectionWindowMs = Number(args["injection-window-ms"] || 20000);

if (!Number.isInteger(port) || port <= 0 || !payloadPath || !logPath ||
    !Number.isInteger(injectionWindowMs) || injectionWindowMs < 5000) {
    throw new Error("Usage: node gpt-rtl-cdp.js --port PORT --payload FILE --log FILE [--injection-window-ms MS]");
}

fs.mkdirSync(path.dirname(logPath), { recursive: true });
function log(message) {
    fs.appendFileSync(logPath, `${new Date().toISOString()} ${message}\n`, "utf8");
}

process.on("uncaughtException", (error) => {
    log(`FATAL ${error.stack || error.message}`);
    process.exitCode = 1;
});
process.on("unhandledRejection", (error) => {
    log(`FATAL ${error && (error.stack || error.message) || error}`);
    process.exitCode = 1;
});

const payload = fs.readFileSync(payloadPath, "utf8");
const versionEndpoint = `http://127.0.0.1:${port}/json/version`;
const targetsEndpoint = `http://127.0.0.1:${port}/json/list`;

function delay(milliseconds) {
    return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function getJson(url) {
    return new Promise((resolve, reject) => {
        const request = http.get(url, { timeout: 2000 }, (response) => {
            let body = "";
            response.setEncoding("utf8");
            response.on("data", (chunk) => { body += chunk; });
            response.on("end", () => {
                if (response.statusCode !== 200) {
                    reject(new Error(`DevTools endpoint returned HTTP ${response.statusCode}`));
                    return;
                }
                try { resolve(JSON.parse(body)); }
                catch (error) { reject(error); }
            });
        });
        request.on("timeout", () => request.destroy(new Error("DevTools endpoint timed out")));
        request.on("error", reject);
    });
}

async function waitForDebugger() {
    const deadline = Date.now() + 45000;
    let lastError;
    while (Date.now() < deadline) {
        try {
            const version = await getJson(versionEndpoint);
            if (version.webSocketDebuggerUrl) return;
        } catch (error) {
            lastError = error;
        }
        await delay(350);
    }
    throw new Error(`GPT did not expose its local DevTools endpoint: ${lastError && lastError.message}`);
}

class PageConnection {
    constructor(socket, target) {
        this.socket = socket;
        this.target = target;
        this.nextId = 1;
        this.pending = new Map();
        socket.addEventListener("message", (event) => this.onMessage(event.data));
        socket.addEventListener("close", () => this.rejectPending(new Error("Page DevTools socket closed")));
        socket.addEventListener("error", () => this.rejectPending(new Error("Page DevTools socket failed")));
    }

    static async connect(target) {
        const socket = new WebSocket(target.webSocketDebuggerUrl);
        await new Promise((resolve, reject) => {
            const timer = setTimeout(() => reject(new Error("Page WebSocket connection timed out")), 5000);
            socket.addEventListener("open", () => {
                clearTimeout(timer);
                resolve();
            }, { once: true });
            socket.addEventListener("error", () => {
                clearTimeout(timer);
                reject(new Error("Page WebSocket connection failed"));
            }, { once: true });
        });
        return new PageConnection(socket, target);
    }

    onMessage(data) {
        let message;
        try { message = JSON.parse(String(data)); }
        catch { return; }
        if (!message.id || !this.pending.has(message.id)) return;
        const pending = this.pending.get(message.id);
        this.pending.delete(message.id);
        clearTimeout(pending.timer);
        if (message.error) pending.reject(new Error(message.error.message));
        else pending.resolve(message.result || {});
    }

    rejectPending(error) {
        for (const pending of this.pending.values()) {
            clearTimeout(pending.timer);
            pending.reject(error);
        }
        this.pending.clear();
    }

    send(method, params = {}) {
        const id = this.nextId++;
        return new Promise((resolve, reject) => {
            const timer = setTimeout(() => {
                this.pending.delete(id);
                reject(new Error(`${method} timed out`));
            }, 7000);
            this.pending.set(id, { resolve, reject, timer });
            this.socket.send(JSON.stringify({ id, method, params }));
        });
    }

    async inject() {
        await this.send("Page.addScriptToEvaluateOnNewDocument", { source: payload }).catch(() => {});
        const evaluation = await this.send("Runtime.evaluate", {
            expression: payload,
            includeCommandLineAPI: false,
            awaitPromise: false,
            returnByValue: false
        });
        if (evaluation.exceptionDetails) {
            throw new Error(evaluation.exceptionDetails.text || "payload evaluation failed");
        }
        const verification = await this.send("Runtime.evaluate", {
            expression: "Boolean(globalThis.__RT_AI_CODEX_RTL_PATCH__)",
            returnByValue: true
        });
        if (!verification.result || verification.result.value !== true) {
            throw new Error("Rightly payload marker was not found after evaluation");
        }
        log(`Injected and verified Rightly payload in ${this.target.type} ${this.target.url || ""}`);
    }

    close() {
        try { this.socket.close(); } catch { }
    }
}

function isInjectableTarget(target) {
    return target && target.webSocketDebuggerUrl &&
        ["page", "webview", "iframe"].includes(target.type);
}

async function main() {
    log(`Waiting for official GPT DevTools endpoint on 127.0.0.1:${port}`);
    await waitForDebugger();
    log("Connected to official GPT runtime");

    const deadline = Date.now() + injectionWindowMs;
    const connections = new Map();
    const retryAfter = new Map();
    let injectionCount = 0;
    let lastError;

    while (Date.now() < deadline) {
        let targets = [];
        try {
            targets = await getJson(targetsEndpoint);
        } catch (error) {
            lastError = error;
            await delay(400);
            continue;
        }

        for (const target of targets) {
            if (!isInjectableTarget(target) || connections.has(target.id)) continue;
            if ((retryAfter.get(target.id) || 0) > Date.now()) continue;
            let connection;
            try {
                connection = await PageConnection.connect(target);
                await connection.inject();
                connections.set(target.id, connection);
                retryAfter.delete(target.id);
                injectionCount++;
            } catch (error) {
                lastError = error;
                if (connection) connection.close();
                retryAfter.set(target.id, Date.now() + 1000);
                log(`Injection attempt failed for ${target.type} ${target.url || ""}: ${error.message}`);
            }
        }
        await delay(400);
    }

    connections.forEach((connection) => connection.close());
    if (injectionCount === 0) {
        throw new Error("No GPT renderer accepted the Rightly payload" + (lastError ? ": " + lastError.message : ""));
    }
    log(`Startup injection window completed after ${injectionWindowMs}ms; verified ${injectionCount} renderer target(s) and disconnected DevTools`);
    await delay(50);
}

main().catch((error) => {
    log(`FATAL ${error.stack || error.message}`);
    process.exit(1);
});
