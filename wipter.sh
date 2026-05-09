#!/usr/bin/env bash
set -euo pipefail

ulimit -n 1048576 2>/dev/null || ulimit -n 65535 2>/dev/null || true

# Accept both the standalone names used by this script and the WIPTER_* names
# used by main.sh/direct_wipter.sh.
EMAIL="${EMAIL:-${WIPTER_EMAIL:-}}"
PASSWORD="${PASSWORD:-${WIPTER_PASSWORD:-}}"

if [ -z "${EMAIL:-}" ]; then
  read -rp "Wipter email: " EMAIL
fi

if [ -z "${PASSWORD:-}" ]; then
  read -rsp "Wipter password: " PASSWORD
  echo
fi

export EMAIL
export PASSWORD
export WIPTER_EMAIL="$EMAIL"
export WIPTER_PASSWORD="$PASSWORD"

WIPTER_LAUNCH_PID=""
HEADLESS="${HEADLESS:-1}"        # 1=headless via Xvfb, 0=normal GUI, auto=headless only when DISPLAY is missing
WIPTER_LOG="${WIPTER_LOG:-/tmp/wipter-seed-launch.log}"
FINAL_WIPTER_LOG="${FINAL_WIPTER_LOG:-/tmp/wipter-run.log}"
WIPTER_DEVTOOLS_PORT="${WIPTER_DEVTOOLS_PORT:-9222}"
WIPTER_USER_DATA_DIR="${WIPTER_USER_DATA_DIR:-}"
RUN_AFTER_SEED="${RUN_AFTER_SEED:-1}"  # 0=seed/sign-in only, then exit; 1=seed, then start Wipter in the same DBus/keyring session
KEYRING_LOG="${KEYRING_LOG:-/tmp/wipter-seed-keyring.log}"
SKIP_KEYTAR="${SKIP_KEYTAR:-0}"  # 1=do not write Linux Secret Service/keytar tokens; localStorage is still seeded
KEYRING_PASSWORD="${KEYRING_PASSWORD:-}"  # default blank keyring password for non-interactive headless use
WIPTER_AFTER_SEED_HOOK="${WIPTER_AFTER_SEED_HOOK:-}"  # optional script run after seeding, before final Wipter launch
WIPTER_LOCALSTORAGE_SEED="${WIPTER_LOCALSTORAGE_SEED:-1}"  # 1=launch Electron and inject localStorage via DevTools; 0=keytar-only diagnostic fallback
WIPTER_CLEAR_AUTH_STORAGE="${WIPTER_CLEAR_AUTH_STORAGE:-1}"  # 1=clear old Wipter/Cognito auth keys before writing fresh tokens
WIPTER_VERIFY_LOCALSTORAGE="${WIPTER_VERIFY_LOCALSTORAGE:-1}"  # 1=read back seeded keys before final launch
WIPTER_SEED_SETTLE_SECONDS="${WIPTER_SEED_SETTLE_SECONDS:-3}"  # wait after injection so Chromium flushes storage

# Wipter/keytar on Linux talks to org.freedesktop.secrets over DBus.
# Some headless environments set DBUS_SESSION_BUS_ADDRESS=disabled:, which makes
# libsecret fail with: Unknown or unsupported transport "disabled". Always put
# the whole run inside a private DBus session on Linux, including the temporary
# Electron launch, so Wipter can read the saved keychain token later.
if [ "$(uname -s)" = "Linux" ]; then
  if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
    export XDG_RUNTIME_DIR="/tmp/wipter-runtime-$(id -u)"
    mkdir -p "$XDG_RUNTIME_DIR"
    chmod 700 "$XDG_RUNTIME_DIR"
  fi

  if [ "${WIPTER_DBUS_SESSION_READY:-0}" != "1" ] || \
     [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] || \
     case "${DBUS_SESSION_BUS_ADDRESS:-}" in disabled:*) true ;; *) false ;; esac; then
    if ! command -v dbus-run-session >/dev/null 2>&1; then
      cat >&2 <<'EOF'
Missing dbus-run-session, which is needed for no-prompt headless keyring setup.
Install it with:
  sudo apt-get update && sudo apt-get install -y dbus dbus-x11 dbus-user-session
EOF
      exit 1
    fi

    export WIPTER_DBUS_SESSION_READY=1
    unset DBUS_SESSION_BUS_ADDRESS
    exec dbus-run-session -- "$0" "$@"
  fi
fi

if [ "$(uname -s)" = "Linux" ]; then
  case "${DBUS_SESSION_BUS_ADDRESS:-}" in
    disabled:*)
      echo "DBUS_SESSION_BUS_ADDRESS is still disabled after setup; refusing to continue." >&2
      echo "Run: unset DBUS_SESSION_BUS_ADDRESS" >&2
      exit 1
      ;;
  esac
fi

need_xvfb() {
  [ "$HEADLESS" = "1" ] || { [ "$HEADLESS" = "auto" ] && [ -z "${DISPLAY:-}" ]; }
}

start_secret_service_for_keytar() {
  [ "$(uname -s)" = "Linux" ] || return 0

  if ! command -v gnome-keyring-daemon >/dev/null 2>&1; then
    cat >&2 <<'EOF'
Missing gnome-keyring-daemon, which provides org.freedesktop.secrets for keytar.
Install dependencies with:
  sudo apt-get update && sudo apt-get install -y gnome-keyring libsecret-tools libsecret-1-0
EOF
    exit 1
  fi

  mkdir -p "${XDG_DATA_HOME:-$HOME/.local/share}/keyrings"
  : >"$KEYRING_LOG"

  echo "Starting headless Secret Service keyring..."

  # --unlock reads the keyring password from stdin. The default is blank, so it
  # can create/unlock the keyring without a GUI dialog on fresh headless systems.
  # If you already have a non-blank keyring password, pass KEYRING_PASSWORD=... .
  keyring_env="$({ printf '%s\n' "$KEYRING_PASSWORD" | gnome-keyring-daemon --unlock --components=secrets; } 2>>"$KEYRING_LOG" || true)"
  if [ -n "$keyring_env" ]; then
    eval "$keyring_env"
  fi

  keyring_env="$(gnome-keyring-daemon --start --components=secrets 2>>"$KEYRING_LOG" || true)"
  if [ -n "$keyring_env" ]; then
    eval "$keyring_env"
  fi

  export GNOME_KEYRING_CONTROL GNOME_KEYRING_PID SSH_AUTH_SOCK

  # Probe/create the default collection now with DISPLAY disabled. If anything
  # would require a GUI prompt, this fails here instead of blocking later.
  if command -v secret-tool >/dev/null 2>&1; then
    if ! printf 'ok' | DISPLAY= WAYLAND_DISPLAY= secret-tool store \
      --label='wipter seed keyring init' \
      application wipter-seed purpose keyring-init \
      >/dev/null 2>>"$KEYRING_LOG"; then
      cat >&2 <<EOF
Could not create/unlock the keyring without a GUI prompt.

Options:
  1. Fresh headless keyring with blank password:
     rm -rf "${XDG_DATA_HOME:-$HOME/.local/share}/keyrings"
     KEYRING_PASSWORD='' $0

  2. Existing keyring with a password:
     KEYRING_PASSWORD='your-keyring-password' $0

  3. Diagnostic-only fallback: SKIP_KEYTAR=1 skips writing the token with
     keytar, but Wipter itself may still need Secret Service to stay logged in.

Keyring log: $KEYRING_LOG
EOF
      exit 1
    fi

    DISPLAY= WAYLAND_DISPLAY= secret-tool clear \
      application wipter-seed purpose keyring-init \
      >/dev/null 2>&1 || true
  fi
}

cleanup_wipter() {
  # Give Electron a moment to flush Chromium storage, then close only the
  # temporary seeding process/profile that this script launched. Do not pkill
  # all wipter-app processes, because direct_wipter.sh may be running many
  # isolated instances at the same time.
  sleep "${WIPTER_SEED_SETTLE_SECONDS:-3}"

  if [ -n "${WIPTER_USER_DATA_DIR:-}" ]; then
    # The user-data-dir is unique per Wipter instance, so this is safer than a
    # global pkill and catches Electron children that xvfb-run leaves behind.
    while read -r pid; do
      [ -n "$pid" ] && kill -TERM "$pid" >/dev/null 2>&1 || true
    done < <(pgrep -f -- "$WIPTER_USER_DATA_DIR" 2>/dev/null || true)
    sleep 1
    while read -r pid; do
      [ -n "$pid" ] && kill -KILL "$pid" >/dev/null 2>&1 || true
    done < <(pgrep -f -- "$WIPTER_USER_DATA_DIR" 2>/dev/null || true)
  fi

  if [ -n "${WIPTER_LAUNCH_PID:-}" ]; then
    pkill -TERM -P "$WIPTER_LAUNCH_PID" >/dev/null 2>&1 || true
    kill "$WIPTER_LAUNCH_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup_wipter EXIT

if [ "${WIPTER_LOCALSTORAGE_SEED:-0}" = "1" ]; then
  echo "Preparing Wipter seeding instance on DevTools port $WIPTER_DEVTOOLS_PORT..."
  echo "Note: Wipter/Electron may ignore custom DevTools ports; direct_wipter.sh now uses fixed 9222 per namespace."
else
  echo "Preparing Wipter keytar-only seed; DevTools/localStorage injection disabled."
fi

WIPTER_ARGS=(
  --remote-debugging-port="$WIPTER_DEVTOOLS_PORT"
  --disable-gpu
  --disable-dev-shm-usage
  --no-sandbox
)
if [ -n "${WIPTER_USER_DATA_DIR:-}" ]; then
  mkdir -p "$WIPTER_USER_DATA_DIR"
  WIPTER_ARGS+=(--user-data-dir="$WIPTER_USER_DATA_DIR")
fi

start_wipter_for_seeding() {
  unset ELECTRON_RUN_AS_NODE

  if need_xvfb; then
    if ! command -v xvfb-run >/dev/null 2>&1; then
      cat >&2 <<'EOF'
Headless mode needs xvfb-run, but it was not found.

Install it, then rerun this script. For example, on Debian/Ubuntu:
  sudo apt-get update && sudo apt-get install -y xvfb

Or run with HEADLESS=0 if you intentionally want to use a real GUI display.
EOF
      exit 1
    fi

    echo "Starting Wipter headlessly under Xvfb for seeding..."
    xvfb-run -a -s "-screen 0 1280x800x24 -nolisten tcp" \
      wipter-app "${WIPTER_ARGS[@]}" >"$WIPTER_LOG" 2>&1 &
    WIPTER_LAUNCH_PID=$!
  else
    echo "Starting Wipter with the current DISPLAY for seeding..."
    wipter-app "${WIPTER_ARGS[@]}" >"$WIPTER_LOG" 2>&1 &
    WIPTER_LAUNCH_PID=$!
  fi
}

start_secret_service_for_keytar

if [ "${WIPTER_LOCALSTORAGE_SEED:-0}" = "1" ]; then
  start_wipter_for_seeding
  # Give Electron a moment to start before the Node seeding code starts polling.
  sleep 1
else
  echo "Skipping temporary Electron launch for seeding."
fi

# Node mode does not need a GUI. Clearing DISPLAY/WAYLAND_DISPLAY prevents
# libsecret/keytar from opening a keyring dialog. Do NOT clear
# DBUS_SESSION_BUS_ADDRESS; keytar needs the private DBus session above.
DISPLAY= WAYLAND_DISPLAY= ELECTRON_RUN_AS_NODE=1 WIPTER_CLEAR_AUTH_STORAGE="$WIPTER_CLEAR_AUTH_STORAGE" WIPTER_VERIFY_LOCALSTORAGE="$WIPTER_VERIFY_LOCALSTORAGE" WIPTER_SEED_SETTLE_SECONDS="$WIPTER_SEED_SETTLE_SECONDS" WIPTER_LAST_AUTH_USER="${WIPTER_LAST_AUTH_USER:-}" /opt/Wipter/wipter-app.bin <<'NODE'
const https = require("https");
const http = require("http");
const net = require("net");
const crypto = require("crypto");
const os = require("os");
const fs = require("fs");
const path = require("path");

function uniqueExisting(paths) {
  return Array.from(new Set(paths.filter(Boolean))).filter(p => {
    try {
      fs.accessSync(p, fs.constants.R_OK);
      return true;
    } catch {
      return false;
    }
  });
}

function findKeytarCandidates() {
  const candidates = [];
  const resourcesPath = process.resourcesPath || "/opt/Wipter/resources";

  candidates.push(
    process.env.WIPTER_KEYTAR_PATH,
    "/opt/Wipter/resources/app.asar.unpacked/node_modules/keytar",
    "/opt/Wipter/resources/app.asar.unpacked/node_modules/keytar/build/Release/keytar.node",
    path.join(resourcesPath, "app.asar.unpacked", "node_modules", "keytar"),
    path.join(resourcesPath, "app.asar.unpacked", "node_modules", "keytar", "build", "Release", "keytar.node")
  );

  // Newer Wipter builds may not keep keytar at the old fixed path. Search only
  // the app resources tree, and keep the walk intentionally small so failures
  // stay fast in headless runs.
  const roots = uniqueExisting([
    path.join(resourcesPath, "app.asar.unpacked"),
    path.join(resourcesPath, "app.asar.unpacked", "node_modules"),
    resourcesPath,
  ]);

  const seenDirs = new Set();
  let visited = 0;
  const maxVisited = 4000;

  function walk(dir, depth) {
    if (!dir || seenDirs.has(dir) || visited++ > maxVisited || depth > 8) return;
    seenDirs.add(dir);

    let entries;
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }

    for (const entry of entries) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        if (entry.name === "keytar") {
          candidates.push(full);
          candidates.push(path.join(full, "build", "Release", "keytar.node"));
        }
        if (entry.name === "Release" && full.includes(`${path.sep}keytar${path.sep}build${path.sep}Release`)) {
          candidates.push(path.join(full, "keytar.node"));
        }
        if (entry.name === "node_modules" || entry.name === "keytar" || depth < 5) {
          walk(full, depth + 1);
        }
      } else if (entry.isFile() && entry.name === "keytar.node") {
        candidates.push(full);
      }
    }
  }

  for (const root of roots) walk(root, 0);
  return uniqueExisting(candidates);
}

function loadKeytar() {
  const candidates = findKeytarCandidates();
  const errors = [];
  for (const candidate of candidates) {
    try {
      const loaded = require(candidate);
      console.log(`Loaded keytar from ${candidate}`);
      return loaded;
    } catch (err) {
      errors.push(`${candidate}: ${err && err.message ? err.message : err}`);
    }
  }

  if (process.env.WIPTER_DEBUG_KEYTAR === "1" && errors.length) {
    console.error("Keytar load attempts failed:");
    for (const err of errors) console.error(`  - ${err}`);
  }
  return null;
}

const REGION = "us-west-2";
const USER_POOL_ID = "us-west-2_ErAI4NHT1";
const CLIENT_ID = "4isku1tmrioog84a88qkl7cnd4";
const POOL_NAME = USER_POOL_ID.split("_")[1];

const KEYTAR_ACCESS_SERVICE = "com.wipter.auth.production";
const KEYTAR_REFRESH_SERVICE = "com.wipter.auth.refresh.token.production";

const email = process.env.EMAIL;
const password = process.env.PASSWORD;
let skipKeytar = process.env.SKIP_KEYTAR === "1";
const devtoolsPort = process.env.WIPTER_DEVTOOLS_PORT || "9222";
const localStorageSeed = process.env.WIPTER_LOCALSTORAGE_SEED === "1";
const clearAuthStorage = process.env.WIPTER_CLEAR_AUTH_STORAGE !== "0";
const verifyLocalStorage = process.env.WIPTER_VERIFY_LOCALSTORAGE !== "0";
const seedSettleMs = Math.max(0, Number(process.env.WIPTER_SEED_SETTLE_SECONDS || "3") * 1000);
const keytar = skipKeytar ? null : loadKeytar();
if (!keytar && !skipKeytar) {
  console.log("keytar module was not found in this Wipter build; continuing with Electron localStorage seeding only.");
  console.log("Set WIPTER_DEBUG_KEYTAR=1 to print attempted keytar paths.");
  skipKeytar = true;
}

function uniqueNonEmpty(values) {
  return Array.from(new Set(values.filter(v => typeof v === "string" && v.length > 0)));
}


// 3072-bit RFC 5054 group used by AWS Cognito SRP.
const N_HEX =
  "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD1" +
  "29024E088A67CC74020BBEA63B139B22514A08798E3404DD" +
  "EF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245" +
  "E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED" +
  "EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3D" +
  "C2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F" +
  "83655D23DCA3AD961C62F356208552BB9ED529077096966D" +
  "670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B" +
  "E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9" +
  "DE2BCBF6955817183995497CEA956AE515D2261898FA05101" +
  "5728E5A8AAAC42DAD33170D04507A33A85521ABDF1CBA64E" +
  "CFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7A" +
  "BF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6B" +
  "F12FFA06D98A0864D87602733EC86A64521F2B18177B200C" +
  "BBE117577A615D6C770988C0BAD946E208E24FA074E5AB31" +
  "43DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF";

const N = BigInt("0x" + N_HEX);
const g = 2n;

function padHex(hex) {
  if (hex.length % 2 === 1) hex = "0" + hex;
  if ("89ABCDEFabcdef".includes(hex[0])) hex = "00" + hex;
  return hex;
}

function bigIntToBuffer(n) {
  return Buffer.from(padHex(n.toString(16)), "hex");
}

function hexToBigInt(hex) {
  return BigInt("0x" + hex);
}

function hash(buffer) {
  return crypto.createHash("sha256").update(buffer).digest();
}

function hashHex(buffer) {
  return crypto.createHash("sha256").update(buffer).digest("hex");
}

function hmac(key, data) {
  return crypto.createHmac("sha256", key).update(data).digest();
}

function modPow(base, exp, mod) {
  let result = 1n;
  base = base % mod;

  while (exp > 0n) {
    if (exp % 2n === 1n) result = (result * base) % mod;
    exp = exp / 2n;
    base = (base * base) % mod;
  }

  return result;
}

function hkdf(ikm, salt) {
  const prk = hmac(salt, ikm);
  const info = Buffer.concat([
    Buffer.from("Caldera Derived Key", "utf8"),
    Buffer.from([1]),
  ]);

  return hmac(prk, info).subarray(0, 16);
}

function cognitoTimestamp() {
  const d = new Date();
  const days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
  const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

  const pad = n => String(n).padStart(2, "0");

  return `${days[d.getUTCDay()]} ${months[d.getUTCMonth()]} ${d.getUTCDate()} ` +
    `${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}:${pad(d.getUTCSeconds())} UTC ${d.getUTCFullYear()}`;
}

function cognito(action, payload) {
  const body = JSON.stringify(payload);

  return new Promise((resolve, reject) => {
    const req = https.request({
      hostname: `cognito-idp.${REGION}.amazonaws.com`,
      method: "POST",
      headers: {
        "Content-Type": "application/x-amz-json-1.1",
        "X-Amz-Target": `AWSCognitoIdentityProviderService.${action}`,
        "Content-Length": Buffer.byteLength(body),
      },
    }, res => {
      let data = "";

      res.on("data", chunk => data += chunk);

      res.on("end", () => {
        let json;

        try {
          json = JSON.parse(data);
        } catch {
          reject({
            message: "Could not parse Cognito response",
            statusCode: res.statusCode,
            raw: data,
          });
          return;
        }

        if (res.statusCode >= 300 || json.__type) {
          reject(json);
        } else {
          resolve(json);
        }
      });
    });

    req.on("error", reject);
    req.write(body);
    req.end();
  });
}

function decodeJwtPayload(jwt) {
  const [, payload] = jwt.split(".");
  if (!payload) return {};
  const normalized = payload.replace(/-/g, "+").replace(/_/g, "/");
  const padded = normalized + "=".repeat((4 - normalized.length % 4) % 4);
  return JSON.parse(Buffer.from(padded, "base64").toString("utf8"));
}

async function srpLogin() {
  const k = hexToBigInt(hashHex(Buffer.concat([
    bigIntToBuffer(N),
    bigIntToBuffer(g),
  ])));

  const a = hexToBigInt(crypto.randomBytes(128).toString("hex"));
  const A = modPow(g, a, N);

  const init = await cognito("InitiateAuth", {
    AuthFlow: "USER_SRP_AUTH",
    ClientId: CLIENT_ID,
    AuthParameters: {
      USERNAME: email,
      SRP_A: A.toString(16),
    },
  });

  if (init.ChallengeName !== "PASSWORD_VERIFIER") {
    throw {
      message: "Unexpected Cognito challenge",
      challenge: init,
    };
  }

  const cp = init.ChallengeParameters;
  const userIdForSrp = cp.USER_ID_FOR_SRP;
  const saltHex = cp.SALT;
  const B = hexToBigInt(cp.SRP_B);
  const secretBlock = Buffer.from(cp.SECRET_BLOCK, "base64");

  const u = hexToBigInt(hashHex(Buffer.concat([
    bigIntToBuffer(A),
    bigIntToBuffer(B),
  ])));

  const userPasswordHash = hash(
    Buffer.from(`${POOL_NAME}${userIdForSrp}:${password}`, "utf8")
  );

  const x = hexToBigInt(hashHex(Buffer.concat([
    Buffer.from(saltHex, "hex"),
    userPasswordHash,
  ])));

  const gModPowX = modPow(g, x, N);

  let base = (B - k * gModPowX) % N;
  if (base < 0n) base += N;

  const exponent = a + u * x;
  const S = modPow(base, exponent, N);

  const key = hkdf(bigIntToBuffer(S), bigIntToBuffer(u));
  const ts = cognitoTimestamp();

  const signature = hmac(key, Buffer.concat([
    Buffer.from(POOL_NAME, "utf8"),
    Buffer.from(userIdForSrp, "utf8"),
    secretBlock,
    Buffer.from(ts, "utf8"),
  ])).toString("base64");

  const response = await cognito("RespondToAuthChallenge", {
    ClientId: CLIENT_ID,
    ChallengeName: "PASSWORD_VERIFIER",
    ChallengeResponses: {
      USERNAME: userIdForSrp,
      PASSWORD_CLAIM_SECRET_BLOCK: cp.SECRET_BLOCK,
      PASSWORD_CLAIM_SIGNATURE: signature,
      TIMESTAMP: ts,
    },
  });

  if (!response.AuthenticationResult?.AccessToken) {
    throw {
      message: "Login did not return an access token",
      response,
    };
  }

  return response.AuthenticationResult;
}

function httpJson(url) {
  return new Promise((resolve, reject) => {
    const req = http.get(url, res => {
      let data = "";
      res.on("data", chunk => data += chunk);
      res.on("end", () => {
        try {
          resolve(JSON.parse(data));
        } catch (err) {
          reject(err);
        }
      });
    });

    req.on("error", reject);
    req.setTimeout(1000, () => {
      req.destroy(new Error("Timed out connecting to Wipter DevTools port"));
    });
  });
}

async function waitForDevtoolsTargets() {
  let lastSeen = [];
  for (let i = 0; i < 160; i++) {
    try {
      const targets = await httpJson(`http://127.0.0.1:${devtoolsPort}/json/list`);
      if (Array.isArray(targets)) {
        lastSeen = targets;
        const usable = targets.filter(t => t.webSocketDebuggerUrl && (!t.type || t.type === "page" || t.type === "webview" || t.type === "other"));
        if (usable.length > 0) {
          console.log(`DevTools targets found: ${usable.map(t => `${t.type || "unknown"}:${t.url || "<no-url>"}`).join(" | ")}`);
          return usable;
        }
      }
    } catch {}
    await new Promise(resolve => setTimeout(resolve, 250));
  }

  const seen = Array.isArray(lastSeen) ? lastSeen.map(t => `${t.type || "unknown"}:${t.url || "<no-url>"}`).join(" | ") : "none";
  throw new Error(`Could not find a Wipter page target on DevTools port ${devtoolsPort}. Last targets: ${seen}. Check ${process.env.WIPTER_LOG || "/tmp/wipter-seed-launch.log"}`);
}

function encodeWsFrame(text) {
  const payload = Buffer.from(text);
  let header;

  if (payload.length < 126) {
    header = Buffer.alloc(2);
    header[1] = 0x80 | payload.length;
  } else if (payload.length < 65536) {
    header = Buffer.alloc(4);
    header[1] = 0x80 | 126;
    header.writeUInt16BE(payload.length, 2);
  } else {
    header = Buffer.alloc(10);
    header[1] = 0x80 | 127;
    header.writeBigUInt64BE(BigInt(payload.length), 2);
  }

  header[0] = 0x81;

  const mask = crypto.randomBytes(4);
  const masked = Buffer.alloc(payload.length);
  for (let i = 0; i < payload.length; i++) {
    masked[i] = payload[i] ^ mask[i % 4];
  }

  return Buffer.concat([header, mask, masked]);
}

function parseWsFrames(buffer) {
  const messages = [];
  let offset = 0;

  while (offset + 2 <= buffer.length) {
    const byte1 = buffer[offset];
    const opcode = byte1 & 0x0f;
    const byte2 = buffer[offset + 1];
    const masked = Boolean(byte2 & 0x80);
    let length = byte2 & 0x7f;
    let headerLen = 2;

    if (length === 126) {
      if (offset + 4 > buffer.length) break;
      length = buffer.readUInt16BE(offset + 2);
      headerLen = 4;
    } else if (length === 127) {
      if (offset + 10 > buffer.length) break;
      length = Number(buffer.readBigUInt64BE(offset + 2));
      headerLen = 10;
    }

    const maskLen = masked ? 4 : 0;
    const frameLen = headerLen + maskLen + length;
    if (offset + frameLen > buffer.length) break;

    let payload = buffer.subarray(offset + headerLen + maskLen, offset + frameLen);

    if (masked) {
      const mask = buffer.subarray(offset + headerLen, offset + headerLen + 4);
      const unmasked = Buffer.alloc(payload.length);
      for (let i = 0; i < payload.length; i++) {
        unmasked[i] = payload[i] ^ mask[i % 4];
      }
      payload = unmasked;
    }

    if (opcode === 1) {
      messages.push(payload.toString("utf8"));
    }

    offset += frameLen;
  }

  return {
    messages,
    remaining: buffer.subarray(offset),
  };
}

function cdpEvaluate(wsUrl, expression, timeoutMs = 15000) {
  return new Promise((resolve, reject) => {
    const url = new URL(wsUrl);
    const key = crypto.randomBytes(16).toString("base64");
    const socket = net.connect(Number(url.port), url.hostname);

    let handshakeDone = false;
    let buffer = Buffer.alloc(0);
    let responseBuffer = "";

    const id = 1;
    const message = JSON.stringify({
      id,
      method: "Runtime.evaluate",
      params: {
        expression,
        awaitPromise: true,
        returnByValue: true,
      },
    });

    const timeout = setTimeout(() => {
      socket.destroy();
      reject(new Error("Timed out while injecting Wipter localStorage"));
    }, timeoutMs);

    socket.on("connect", () => {
      socket.write(
        `GET ${url.pathname}${url.search} HTTP/1.1\r\n` +
        `Host: ${url.host}\r\n` +
        `Upgrade: websocket\r\n` +
        `Connection: Upgrade\r\n` +
        `Sec-WebSocket-Key: ${key}\r\n` +
        `Sec-WebSocket-Version: 13\r\n\r\n`
      );
    });

    socket.on("data", chunk => {
      if (!handshakeDone) {
        responseBuffer += chunk.toString("binary");
        const headerEnd = responseBuffer.indexOf("\r\n\r\n");
        if (headerEnd === -1) return;

        const header = responseBuffer.slice(0, headerEnd);
        if (!header.includes("101")) {
          clearTimeout(timeout);
          socket.destroy();
          reject(new Error(`WebSocket handshake failed: ${header}`));
          return;
        }

        handshakeDone = true;
        const rest = Buffer.from(responseBuffer.slice(headerEnd + 4), "binary");
        responseBuffer = "";
        socket.write(encodeWsFrame(message));
        if (rest.length) buffer = Buffer.concat([buffer, rest]);
      } else {
        buffer = Buffer.concat([buffer, chunk]);
      }

      if (handshakeDone && buffer.length) {
        const parsed = parseWsFrames(buffer);
        buffer = parsed.remaining;

        for (const msg of parsed.messages) {
          const json = JSON.parse(msg);
          if (json.id === id) {
            clearTimeout(timeout);
            socket.end();
            if (json.error) reject(json.error);
            else resolve(json.result);
            return;
          }
        }
      }
    });

    socket.on("error", err => {
      clearTimeout(timeout);
      reject(err);
    });
  });
}

function buildLocalStorageItems(tokens) {
  const emailLower = email.toLowerCase();
  const accessPayload = decodeJwtPayload(tokens.AccessToken);
  const idPayload = tokens.IdToken ? decodeJwtPayload(tokens.IdToken) : {};
  const cognitoUsername = idPayload["cognito:username"] || accessPayload.username || emailLower;
  const userSub = idPayload.sub || accessPayload.sub || accessPayload.username || cognitoUsername;
  const iat = accessPayload.iat ? accessPayload.iat * 1000 : Date.now();
  const clockDrift = String(iat - Date.now());

  const signInDetails = {
    loginId: email,
    authFlowType: "USER_SRP_AUTH",
  };

  const userProfile = {
    username: cognitoUsername,
    userId: userSub,
    sub: userSub,
    email,
    signInDetails,
  };

  const userAliases = uniqueNonEmpty([
    process.env.WIPTER_LAST_AUTH_USER,
    emailLower,
    email,
    cognitoUsername,
    accessPayload.username,
    idPayload["cognito:username"],
    idPayload.email,
    userSub,
  ]);

  const lastAuthUser = process.env.WIPTER_LAST_AUTH_USER || emailLower;
  const items = {
    [`CognitoIdentityServiceProvider.${CLIENT_ID}.LastAuthUser`]: lastAuthUser,
    [KEYTAR_ACCESS_SERVICE]: JSON.stringify({
      access_token: tokens.AccessToken,
      accessToken: tokens.AccessToken,
      token: tokens.AccessToken,
      token_type: "Bearer",
      tokenType: "Bearer",
      id_token: tokens.IdToken || "",
      idToken: tokens.IdToken || "",
      refresh_token: tokens.RefreshToken || "",
      refreshToken: tokens.RefreshToken || "",
      profile: userProfile,
      user: userProfile,
    }),
    [KEYTAR_REFRESH_SERVICE]: tokens.RefreshToken || "",
  };

  for (const alias of userAliases) {
    const base = `CognitoIdentityServiceProvider.${CLIENT_ID}.${alias}`;
    items[`${base}.accessToken`] = tokens.AccessToken;
    items[`${base}.idToken`] = tokens.IdToken || "";
    items[`${base}.refreshToken`] = tokens.RefreshToken || "";
    items[`${base}.clockDrift`] = clockDrift;
    items[`${base}.signInDetails`] = JSON.stringify(signInDetails);
    items[`${base}.userData`] = JSON.stringify({
      UserAttributes: [
        { Name: "sub", Value: userSub },
        { Name: "email", Value: email },
      ],
      Username: cognitoUsername,
    });
  }

  return { items, lastAuthUser, userAliases };
}

function makeSeedExpression(items, lastAuthUser) {
  return `
    new Promise((resolve) => {
      const items = ${JSON.stringify(items)};
      const clearAuthStorage = ${JSON.stringify(clearAuthStorage)};
      const verifyLocalStorage = ${JSON.stringify(verifyLocalStorage)};
      const authPrefixes = [
        "CognitoIdentityServiceProvider.${CLIENT_ID}",
        ${JSON.stringify(KEYTAR_ACCESS_SERVICE)},
        ${JSON.stringify(KEYTAR_REFRESH_SERVICE)}
      ];
      const result = {
        ok: false,
        href: location.href,
        origin: location.origin,
        cleared: 0,
        keysWritten: 0,
        verifiedKeys: 0,
        lastAuthUser: null,
        errors: []
      };

      function shouldClearKey(key) {
        return authPrefixes.some(prefix => key === prefix || key.startsWith(prefix));
      }

      function seedArea(area, areaName) {
        if (!area) return;
        try {
          if (clearAuthStorage) {
            for (const key of Object.keys(area)) {
              if (shouldClearKey(key)) {
                area.removeItem(key);
                result.cleared++;
              }
            }
          }
          for (const [key, value] of Object.entries(items)) {
            if (value !== undefined && value !== null) {
              area.setItem(key, String(value));
              result.keysWritten++;
            }
          }
        } catch (err) {
          result.errors.push(areaName + ": " + (err && err.message ? err.message : String(err)));
        }
      }

      seedArea(localStorage, "localStorage");
      seedArea(sessionStorage, "sessionStorage");

      try {
        result.lastAuthUser = localStorage.getItem(${JSON.stringify(`CognitoIdentityServiceProvider.${CLIENT_ID}.LastAuthUser`)});
        for (const key of Object.keys(items)) {
          if (localStorage.getItem(key) !== null) result.verifiedKeys++;
        }
        result.ok = result.lastAuthUser === ${JSON.stringify(lastAuthUser)} && result.verifiedKeys >= Math.min(5, Object.keys(items).length);
      } catch (err) {
        result.errors.push("verify: " + (err && err.message ? err.message : String(err)));
      }

      try { window.dispatchEvent(new Event("storage")); } catch {}
      setTimeout(() => {
        try { location.reload(); } catch {}
        resolve(result);
      }, 1200);
    })
  `;
}

async function seedElectronLocalStorage(tokens) {
  const { items, lastAuthUser, userAliases } = buildLocalStorageItems(tokens);
  console.log(`Waiting for Wipter DevTools on port ${devtoolsPort}...`);
  console.log(`Prepared ${Object.keys(items).length} auth keys for LastAuthUser=${lastAuthUser}; aliases=${userAliases.join(",")}`);
  const targets = await waitForDevtoolsTargets();

  let successCount = 0;
  const errors = [];
  const expression = makeSeedExpression(items, lastAuthUser);

  for (const target of targets) {
    const label = `${target.type || "unknown"}:${target.url || "<no-url>"}`;
    try {
      const evalResult = await cdpEvaluate(target.webSocketDebuggerUrl, expression, 20000);
      const value = evalResult && evalResult.result ? evalResult.result.value : undefined;
      console.log(`LocalStorage seed target ${label}: ${JSON.stringify(value)}`);
      if (value && value.ok) successCount++;
    } catch (err) {
      const msg = err && err.message ? err.message : JSON.stringify(err);
      console.log(`LocalStorage seed target ${label} failed: ${msg}`);
      errors.push(`${label}: ${msg}`);
    }
  }

  if (successCount === 0) {
    throw new Error(`LocalStorage seed did not verify in any Wipter page target. Errors: ${errors.join(" | ") || "none"}`);
  }

  if (seedSettleMs > 0) {
    console.log(`Waiting ${seedSettleMs}ms for Chromium storage flush...`);
    await new Promise(resolve => setTimeout(resolve, seedSettleMs));
  }
}

async function main() {
  console.log("Logging in to Wipter Cognito...");
  const tokens = await srpLogin();
  console.log("Cognito login succeeded.");

  if (skipKeytar) {
    if (process.env.SKIP_KEYTAR === "1") {
      console.log("Skipping OS keychain/keytar because SKIP_KEYTAR=1.");
    } else {
      console.log("Skipping OS keychain/keytar because the keytar module is not available in this Wipter install.");
    }
  } else {
    console.log("Saving token to OS keychain...");

    const keychainAccounts = uniqueNonEmpty([
      os.userInfo().username,
      process.env.USER,
      process.env.LOGNAME,
      email,
      email.toLowerCase(),
    ]);

    for (const account of keychainAccounts) {
      await keytar.setPassword(
        KEYTAR_ACCESS_SERVICE,
        account,
        tokens.AccessToken
      );

      if (tokens.RefreshToken) {
        await keytar.setPassword(
          KEYTAR_REFRESH_SERVICE,
          account,
          tokens.RefreshToken
        );
      }
    }

    const primaryAccount = os.userInfo().username;
    const readBack = await keytar.getPassword(KEYTAR_ACCESS_SERVICE, primaryAccount);
    if (!readBack) {
      throw new Error(`OS keychain write failed or could not be read back for account ${primaryAccount}`);
    }
    console.log(`OS keychain token verified for account ${primaryAccount}. Also wrote aliases: ${keychainAccounts.join(", ")}`);
  }

  if (localStorageSeed) {
    console.log("Seeding Electron localStorage via DevTools...");
    await seedElectronLocalStorage(tokens);
    console.log("Wipter Electron localStorage seeded.");
  } else {
    console.log("Skipping Electron localStorage seeding because WIPTER_LOCALSTORAGE_SEED=0.");
    if (skipKeytar) {
      console.log("WARNING: keytar is also unavailable/skipped, so Wipter may still redirect to sign in.");
    } else {
      console.log("Using OS keychain/keytar seed only; this is diagnostic fallback and Wipter may still require localStorage.");
    }
  }

  console.log("Wipter access token saved.");
  console.log("Wipter seed phase complete.");
}

main().catch(err => {
  console.error("Headless login failed:");

  if (err && err.stack) {
    console.error(err.stack);
  } else if (err && err.message) {
    console.error(err.message);
    console.error(JSON.stringify(err, null, 2));
  } else {
    console.error(JSON.stringify(err, null, 2));
  }

  process.exit(1);
});
NODE


# Stop the temporary seeding Electron process before launching the real one.
cleanup_wipter
trap - EXIT

if [ -n "${WIPTER_AFTER_SEED_HOOK:-}" ]; then
  echo "Running Wipter after-seed hook before final launch: $WIPTER_AFTER_SEED_HOOK"
  bash "$WIPTER_AFTER_SEED_HOOK"
fi


if [ "${RUN_AFTER_SEED:-0}" = "1" ]; then
  # Keep this process alive so the dbus-run-session bus and gnome-keyring daemon
  # stay available to Wipter at runtime. This is the important difference from
  # seeding first and launching Wipter later from another shell.
  if [ "$#" -eq 0 ]; then
    set -- --hidden
  fi

  echo "Launching Wipter in the SAME DBus/keyring session. Log: $FINAL_WIPTER_LOG"
  echo "Wipter app runtime log location: $FINAL_WIPTER_LOG"

  WIPTER_FINAL_ARGS=(--disable-gpu --disable-dev-shm-usage --no-sandbox)
  if [ -n "${WIPTER_USER_DATA_DIR:-}" ]; then
    mkdir -p "$WIPTER_USER_DATA_DIR"
    WIPTER_FINAL_ARGS+=(--user-data-dir="$WIPTER_USER_DATA_DIR")
  fi

  if need_xvfb; then
    if ! command -v xvfb-run >/dev/null 2>&1; then
      echo "Missing xvfb-run. Install: sudo apt-get install -y xvfb" >&2
      exit 1
    fi
    exec xvfb-run -a -s "-screen 0 1280x800x24 -nolisten tcp"       wipter-app "${WIPTER_FINAL_ARGS[@]}" "$@"       >"$FINAL_WIPTER_LOG" 2>&1
  else
    exec wipter-app "${WIPTER_FINAL_ARGS[@]}" "$@"       >"$FINAL_WIPTER_LOG" 2>&1
  fi
else
  echo "Seed complete. RUN_AFTER_SEED=0, so Wipter was not started."
fi
