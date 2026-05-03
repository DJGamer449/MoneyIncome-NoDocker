#!/usr/bin/env bash
set -euo pipefail

if [ -z "${EMAIL:-}" ]; then
  read -rp "Wipter email: " EMAIL
fi

if [ -z "${PASSWORD:-}" ]; then
  read -rsp "Wipter password: " PASSWORD
  echo
fi

export EMAIL
export PASSWORD

WIPTER_LAUNCH_PID=""
HEADLESS="${HEADLESS:-1}"        # 1=headless via Xvfb, 0=normal GUI, auto=headless only when DISPLAY is missing
WIPTER_LOG="${WIPTER_LOG:-/tmp/wipter-seed-launch.log}"
FINAL_WIPTER_LOG="${FINAL_WIPTER_LOG:-/tmp/wipter-run.log}"
RUN_AFTER_SEED="${RUN_AFTER_SEED:-1}"  # 0=seed/sign-in only, then exit; 1=seed, then start Wipter in the same DBus/keyring session
KEYRING_LOG="${KEYRING_LOG:-/tmp/wipter-seed-keyring.log}"
SKIP_KEYTAR="${SKIP_KEYTAR:-0}"  # 1=do not write Linux Secret Service/keytar tokens; localStorage is still seeded
KEYRING_PASSWORD="${KEYRING_PASSWORD:-}"  # default blank keyring password for non-interactive headless use

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
  # Give Electron a moment to flush Chromium storage, then close it.
  sleep 1
  pkill -f 'wipter-app.*remote-debugging-port=9222' >/dev/null 2>&1 || true
  pkill -f wipter-app >/dev/null 2>&1 || true

  # If we launched through xvfb-run, killing the wrapper helps Xvfb clean itself up.
  if [ -n "${WIPTER_LAUNCH_PID:-}" ]; then
    kill "$WIPTER_LAUNCH_PID" >/dev/null 2>&1 || true
  fi
}

trap cleanup_wipter EXIT

echo "Closing any existing Wipter instances..."
pkill -f wipter-app >/dev/null 2>&1 || true

WIPTER_ARGS=(
  --remote-debugging-port=9222
  --disable-gpu
  --disable-dev-shm-usage
  --no-sandbox
)

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
start_wipter_for_seeding

# Give Electron a moment to start before the Node seeding code starts polling.
sleep 1

# Node mode does not need a GUI. Clearing DISPLAY/WAYLAND_DISPLAY prevents
# libsecret/keytar from opening a keyring dialog. Do NOT clear
# DBUS_SESSION_BUS_ADDRESS; keytar needs the private DBus session above.
DISPLAY= WAYLAND_DISPLAY= ELECTRON_RUN_AS_NODE=1 /opt/Wipter/wipter-app.bin <<'NODE'
const https = require("https");
const http = require("http");
const net = require("net");
const crypto = require("crypto");
const os = require("os");
const keytar = require("/opt/Wipter/resources/app.asar.unpacked/node_modules/keytar");

const REGION = "us-west-2";
const USER_POOL_ID = "us-west-2_ErAI4NHT1";
const CLIENT_ID = "4isku1tmrioog84a88qkl7cnd4";
const POOL_NAME = USER_POOL_ID.split("_")[1];

const KEYTAR_ACCESS_SERVICE = "com.wipter.auth.production";
const KEYTAR_REFRESH_SERVICE = "com.wipter.auth.refresh.token.production";

const email = process.env.EMAIL;
const password = process.env.PASSWORD;
const skipKeytar = process.env.SKIP_KEYTAR === "1";

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

async function waitForDevtools() {
  for (let i = 0; i < 120; i++) {
    try {
      const pages = await httpJson("http://127.0.0.1:9222/json/list");
      const page = pages.find(p => p.type === "page" && p.webSocketDebuggerUrl) || pages.find(p => p.webSocketDebuggerUrl);
      if (page?.webSocketDebuggerUrl) return page.webSocketDebuggerUrl;
    } catch {}

    try {
      const version = await httpJson("http://127.0.0.1:9222/json/version");
      if (version?.webSocketDebuggerUrl) return version.webSocketDebuggerUrl;
    } catch {}

    await new Promise(resolve => setTimeout(resolve, 250));
  }

  throw new Error("Could not connect to Wipter on DevTools port 9222. Check /tmp/wipter-seed-launch.log");
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

function cdpEvaluate(wsUrl, expression) {
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
    }, 5000);

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

async function seedElectronLocalStorage(tokens) {
  const username = email.toLowerCase();
  const accessPayload = decodeJwtPayload(tokens.AccessToken);
  const idPayload = tokens.IdToken ? decodeJwtPayload(tokens.IdToken) : {};
  const cognitoUsername = idPayload["cognito:username"] || accessPayload.username || username;
  const userSub = idPayload.sub || accessPayload.sub;
  const iat = accessPayload.iat ? accessPayload.iat * 1000 : Date.now();
  const clockDrift = String(iat - Date.now());

  const base = `CognitoIdentityServiceProvider.${CLIENT_ID}.${username}`;
  const signInDetails = {
    loginId: email,
    authFlowType: "USER_SRP_AUTH",
  };

  const userProfile = {
    username: cognitoUsername,
    userId: userSub,
    signInDetails,
  };

  const localStorageItems = {
    [`CognitoIdentityServiceProvider.${CLIENT_ID}.LastAuthUser`]: username,
    [`${base}.accessToken`]: tokens.AccessToken,
    [`${base}.idToken`]: tokens.IdToken || "",
    [`${base}.refreshToken`]: tokens.RefreshToken || "",
    [`${base}.clockDrift`]: clockDrift,
    [`${base}.signInDetails`]: JSON.stringify(signInDetails),

    // Wipter's renderer also keeps its own user object under this key.
    [KEYTAR_ACCESS_SERVICE]: JSON.stringify({
      access_token: tokens.AccessToken,
      token_type: "Bearer",
      profile: userProfile,
    }),
  };

  console.log("Waiting for Wipter DevTools on port 9222...");
  const wsUrl = await waitForDevtools();

  const expression = `
    new Promise((resolve) => {
      const items = ${JSON.stringify(localStorageItems)};
      for (const [key, value] of Object.entries(items)) {
        if (value !== undefined && value !== null) {
          localStorage.setItem(key, value);
        }
      }

      // Some Electron/Amplify builds consult sessionStorage during the current run.
      // Mirror the same values there too; localStorage is what persists.
      for (const [key, value] of Object.entries(items)) {
        if (value !== undefined && value !== null) {
          sessionStorage.setItem(key, value);
        }
      }

      setTimeout(() => {
        const result = {
          ok: true,
          keysWritten: Object.keys(items).length,
          lastAuthUser: localStorage.getItem(${JSON.stringify(`CognitoIdentityServiceProvider.${CLIENT_ID}.LastAuthUser`)})
        };

        location.reload();
        resolve(result);
      }, 500);
    })
  `;

  await cdpEvaluate(wsUrl, expression);
}

async function main() {
  console.log("Logging in to Wipter Cognito...");
  const tokens = await srpLogin();
  console.log("Cognito login succeeded.");

  if (skipKeytar) {
    console.log("Skipping OS keychain/keytar because SKIP_KEYTAR=1.");
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

  console.log("Seeding Electron localStorage...");
  await seedElectronLocalStorage(tokens);

  console.log("Wipter access token saved.");
  console.log("Wipter Electron localStorage seeded.");
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

if [ "${RUN_AFTER_SEED:-0}" = "1" ]; then
  # Keep this process alive so the dbus-run-session bus and gnome-keyring daemon
  # stay available to Wipter at runtime. This is the important difference from
  # seeding first and launching Wipter later from another shell.
  if [ "$#" -eq 0 ]; then
    set -- --hidden
  fi

  echo "Launching Wipter in the SAME DBus/keyring session. Log: $FINAL_WIPTER_LOG"

  if need_xvfb; then
    if ! command -v xvfb-run >/dev/null 2>&1; then
      echo "Missing xvfb-run. Install: sudo apt-get install -y xvfb" >&2
      exit 1
    fi
    exec xvfb-run -a -s "-screen 0 1280x800x24 -nolisten tcp" \
      wipter-app --disable-gpu --disable-dev-shm-usage --no-sandbox "$@" \
      >"$FINAL_WIPTER_LOG" 2>&1
  else
    exec wipter-app --disable-gpu --disable-dev-shm-usage --no-sandbox "$@" \
      >"$FINAL_WIPTER_LOG" 2>&1
  fi
else
  echo "Seed complete. RUN_AFTER_SEED=0, so Wipter was not started."
fi
