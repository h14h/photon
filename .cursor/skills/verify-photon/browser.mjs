import { chromium } from "playwright-core";
import fs from "node:fs";
import net from "node:net";
import path from "node:path";

const verifyRoot = process.env.PHOTON_VERIFY_ROOT || "/tmp/verify-photon";
const runDir = path.join(verifyRoot, "run");
const sockPath = path.join(runDir, "browser.sock");
const readyPath = path.join(runDir, "browser.ready");

function parseFlags(argv) {
  const opts = {};
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (!arg.startsWith("--")) {
      throw new Error(`unexpected argument ${arg}`);
    }
    const key = arg.slice(2);
    if (key === "confirm") {
      opts.confirm = true;
      continue;
    }
    const value = argv[i + 1];
    if (value === undefined || value.startsWith("--")) {
      throw new Error(`missing value for --${key}`);
    }
    opts[key] = value;
    i++;
  }
  return opts;
}

function readPort() {
  const port = Number(fs.readFileSync(path.join(runDir, "port"), "utf8").trim());
  if (!Number.isInteger(port) || port <= 0) throw new Error("run/port is not a port");
  return port;
}

function baseUrl() {
  return `http://127.0.0.1:${readPort()}`;
}

function listenInodes(port) {
  const hex = port.toString(16).toUpperCase().padStart(4, "0");
  const inodes = new Set();
  for (const file of ["/proc/net/tcp", "/proc/net/tcp6"]) {
    let text;
    try {
      text = fs.readFileSync(file, "utf8");
    } catch {
      continue;
    }
    for (const line of text.trim().split("\n").slice(1)) {
      const parts = line.trim().split(/\s+/);
      const [addr, portHex] = parts[1].split(":");
      if (portHex.toUpperCase() !== hex || parts[3] !== "0A") continue;
      if (addr.toUpperCase() !== "0100007F") {
        throw new Error(
          `port ${port} is listening on ${addr}, not 127.0.0.1; verification will not drive it`,
        );
      }
      inodes.add(parts[9]);
    }
  }
  return inodes;
}

function pidForInodes(inodes) {
  if (inodes.size === 0) return null;
  for (const dir of fs.readdirSync("/proc")) {
    if (!/^\d+$/.test(dir)) continue;
    let fds;
    try {
      fds = fs.readdirSync(`/proc/${dir}/fd`);
    } catch {
      continue;
    }
    for (const fd of fds) {
      let target;
      try {
        target = fs.readlinkSync(`/proc/${dir}/fd/${fd}`);
      } catch {
        continue;
      }
      const match = /^socket:\[(\d+)\]$/.exec(target);
      if (match && inodes.has(match[1])) return Number(dir);
    }
  }
  return null;
}

function ancestors(pid) {
  const found = [];
  let current = pid;
  for (let i = 0; i < 30; i++) {
    let status;
    try {
      status = fs.readFileSync(`/proc/${current}/status`, "utf8");
    } catch {
      break;
    }
    const match = /^PPid:\s+(\d+)/m.exec(status);
    if (!match) break;
    const parent = Number(match[1]);
    if (parent <= 1) break;
    found.push(parent);
    current = parent;
  }
  return found;
}

function listenPid(port, expect) {
  const inodes = listenInodes(port);
  const pid = pidForInodes(inodes);
  if (pid == null) {
    console.error(`nothing is listening on 127.0.0.1:${port}`);
    process.exit(1);
  }
  if (expect != null) {
    const expected = Number(expect);
    const owned = pid === expected || ancestors(pid).includes(expected);
    if (!owned) {
      console.error(`port ${port} is owned by pid ${pid}, not verify-photon pid ${expected}`);
      process.exit(2);
    }
  }
  process.stdout.write(`${pid}\n`);
}

function checkHome(homePath, nodesPath, dataDir) {
  const home = fs.readFileSync(homePath, "utf8");
  const nodes = fs.readFileSync(nodesPath, "utf8");
  const errors = [];
  if (home.includes("Photon needs its password") || nodes.includes("Photon needs its password")) {
    errors.push("GUI returned the password challenge; launch must leave PHOTON_PASSWORD unset");
  }
  if (!home.includes("Overview · Photon")) {
    errors.push('page is missing the title "Overview · Photon"');
  }
  if (!home.includes('id="blip-face"')) errors.push("Blip is missing from the overview");
  if (!home.includes('id="composer-input"')) {
    if (home.includes('id="sign-in-to-talk"')) {
      errors.push("Blip is waiting for ChatGPT; launch must set PHOTON_MOCK_MODEL=1");
    } else {
      errors.push("textarea#composer-input is missing");
    }
  }
  if (!home.includes('id="side-node-local"') && !home.includes('id="machine-local"')) {
    errors.push("built-in node local is not listed");
  }
  if (home.includes("No nodes are connected") || nodes.includes("No nodes are connected")) {
    errors.push("hub has no connected node");
  }
  if (!nodes.includes('id="node-local"')) errors.push("nodes page does not list local");
  if (!nodes.includes(dataDir)) {
    errors.push(`nodes page does not mention data dir ${dataDir}; refusing to drive a different instance`);
  }
  if (errors.length) {
    for (const error of errors) console.error(`doctor: ${error}`);
    process.exit(1);
  }
}

async function daemon() {
  fs.mkdirSync(runDir, { recursive: true });
  for (const stale of [sockPath, readyPath]) {
    try {
      fs.unlinkSync(stale);
    } catch {
      // absent
    }
  }

  const launch = {
    headless: true,
    args: ["--no-sandbox", "--disable-dev-shm-usage"],
  };
  if (process.env.CHROME_PATH) launch.executablePath = process.env.CHROME_PATH;
  else launch.channel = "chrome";

  const browser = await chromium.launch(launch);
  const context = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  const page = await context.newPage();
  page.setDefaultTimeout(20000);
  page.on("pageerror", (error) => console.error("pageerror", error.message));

  await page.goto(baseUrl(), { waitUntil: "domcontentloaded" });
  // app.js is deferred, so the markup can exist before the LiveView socket connects.
  await page.waitForSelector(".phx-connected", { timeout: 20000 });
  await page.waitForSelector("#blip-face", { timeout: 20000 });
  // The composer sits in the panel, which is visibility:hidden until Blip opens.
  await page.click("#blip-face");
  await page.waitForSelector("#composer-input", { state: "visible", timeout: 20000 });
  fs.writeFileSync(readyPath, "ok\n");

  let chain = Promise.resolve();
  const enqueue = (fn) => {
    const run = chain.then(fn, fn);
    chain = run.then(
      () => {},
      () => {},
    );
    return run;
  };

  const server = net.createServer((socket) => {
    let buf = "";
    socket.on("data", (chunk) => {
      buf += chunk;
      const idx = buf.indexOf("\n");
      if (idx === -1) return;
      const line = buf.slice(0, idx);
      enqueue(async () => {
        let response;
        try {
          response = { ok: true, ...(await handle(page, JSON.parse(line))) };
        } catch (error) {
          response = { ok: false, error: error instanceof Error ? error.message : String(error) };
        }
        socket.end(`${JSON.stringify(response)}\n`);
      }).catch((error) => {
        socket.end(`${JSON.stringify({ ok: false, error: String(error) })}\n`);
      });
    });
  });

  await new Promise((resolve, reject) => {
    server.listen(sockPath, () => resolve());
    server.on("error", reject);
  });

  const shutdown = async () => {
    try {
      server.close();
    } catch {
      // already closing
    }
    try {
      await browser.close();
    } catch {
      // already closed
    }
    try {
      fs.unlinkSync(sockPath);
    } catch {
      // already gone
    }
    process.exit(0);
  };
  process.on("SIGTERM", shutdown);
  process.on("SIGINT", shutdown);
}

async function handle(page, msg) {
  const timeout = msg.timeout ? Number(msg.timeout) : undefined;
  const root = () => (msg.within ? page.locator(msg.within) : page);
  switch (msg.cmd) {
    case "goto": {
      const url = msg.url.startsWith("/") ? `${baseUrl()}${msg.url}` : msg.url;
      await page.goto(url, { waitUntil: "domcontentloaded", timeout: timeout ?? 20000 });
      return { url: page.url() };
    }
    case "fill":
      await page.locator(msg.selector).fill(msg.value, { timeout: timeout ?? 15000 });
      return {};
    case "click": {
      const onDialog = (dialog) => (msg.confirm ? dialog.accept() : dialog.dismiss());
      page.on("dialog", onDialog);
      try {
        await page.locator(msg.selector).click({ timeout: timeout ?? 15000 });
      } finally {
        page.off("dialog", onDialog);
      }
      return {};
    }
    case "press":
      await page.locator(msg.selector).press(msg.key, { timeout: timeout ?? 15000 });
      return {};
    case "hover":
      await page.locator(msg.selector).hover({ timeout: timeout ?? 15000 });
      return {};
    case "select":
      await page.locator(msg.selector).selectOption(msg.value, { timeout: timeout ?? 15000 });
      return {};
    case "check":
      await page.locator(msg.selector).check({ timeout: timeout ?? 15000 });
      return {};
    case "uncheck":
      await page.locator(msg.selector).uncheck({ timeout: timeout ?? 15000 });
      return {};
    case "upload":
      await page.locator(msg.selector).setInputFiles(msg.path, { timeout: timeout ?? 15000 });
      return {};
    case "wait-selector":
      await page.waitForSelector(msg.selector, { timeout: timeout ?? 20000 });
      return {};
    case "wait-text":
      await root()
        .getByText(msg.text, { exact: false })
        .first()
        .waitFor({ timeout: timeout ?? 60000 });
      return {};
    case "wait-url":
      await page.waitForURL((url) => url.href.includes(msg.includes), { timeout: timeout ?? 20000 });
      return { url: page.url() };
    case "text":
      return { text: await page.locator(msg.selector).innerText({ timeout: timeout ?? 15000 }) };
    case "count":
      return { text: String(await page.locator(msg.selector).count()) };
    case "title":
      return { text: await page.title() };
    case "url":
      return { text: page.url() };
    case "screenshot":
      fs.mkdirSync(path.dirname(msg.path), { recursive: true });
      await page.screenshot({ path: msg.path, fullPage: false });
      return { path: msg.path };
    default:
      throw new Error(`unknown browser command ${msg.cmd}`);
  }
}

function rpc(cmd, argv) {
  const opts = parseFlags(argv);
  const payload = { cmd, ...opts };
  return new Promise((resolve, reject) => {
    const socket = net.createConnection(sockPath);
    let buf = "";
    socket.setTimeout(120000);
    socket.on("data", (chunk) => {
      buf += chunk;
    });
    socket.on("error", reject);
    socket.on("timeout", () => {
      socket.destroy();
      reject(new Error("browser daemon timed out"));
    });
    socket.on("end", () => {
      try {
        const msg = JSON.parse(buf);
        if (!msg.ok) reject(new Error(msg.error || "browser command failed"));
        else resolve(msg);
      } catch (error) {
        reject(error);
      }
    });
    socket.write(`${JSON.stringify(payload)}\n`);
  });
}

const command = process.argv[2];
if (!command) {
  console.error("usage: browser.mjs <daemon|check-home|listen-pid|command>");
  process.exit(2);
}

if (command === "daemon") {
  await daemon();
} else if (command === "check-home") {
  checkHome(process.argv[3], process.argv[4], process.argv[5]);
} else if (command === "listen-pid") {
  listenPid(Number(process.argv[3]), process.argv[4]);
} else {
  try {
    const msg = await rpc(command, process.argv.slice(3));
    if (msg.text != null) process.stdout.write(msg.text.endsWith("\n") ? msg.text : `${msg.text}\n`);
    else process.stdout.write("ok\n");
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exit(1);
  }
}
