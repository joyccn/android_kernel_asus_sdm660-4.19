#!/usr/bin/env python3
import glob
import json
import os
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN") or os.environ.get("TG_TOKEN")
ADMIN_ID = os.environ.get("TELEGRAM_ADMIN_ID")
OUTPUT_CHAT_ID = os.environ.get("TELEGRAM_OUTPUT_CHAT_ID") or os.environ.get("TG_CHAT_ID")
KERNEL_DIR = os.environ.get("KERNEL_DIR", os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))
BUILD_SCRIPT = os.environ.get("BUILD_SCRIPT", os.path.join(KERNEL_DIR, "build-prism.sh"))
RELEASE_DIR = os.environ.get("RELEASE_DIR", os.path.join(KERNEL_DIR, "..", "releases"))
POLL_TIMEOUT = int(os.environ.get("TELEGRAM_POLL_TIMEOUT", "30"))

BUILD_LOCK = threading.Lock()
CURRENT_BUILD = {"running": False, "variant": None, "started": None}
BUILD_PROC = None

COMMANDS = [
    {"command": "start", "description": "Tampilkan menu build"},
    {"command": "build", "description": "Build kernel (noksu/ksu/both)"},
    {"command": "cancel", "description": "Batalkan build yang sedang jalan"},
    {"command": "status", "description": "Cek status build saat ini"},
]


def die(message):
    print(message, file=sys.stderr)
    sys.exit(1)


if not TOKEN:
    die("Set TELEGRAM_BOT_TOKEN or TG_TOKEN.")


def api(method, data=None, files=None):
    url = "https://api.telegram.org/bot%s/%s" % (TOKEN, method)
    data = data or {}

    if files:
        return multipart_api(url, data, files)

    encoded = urllib.parse.urlencode(data).encode()
    req = urllib.request.Request(url, data=encoded)
    with urllib.request.urlopen(req, timeout=POLL_TIMEOUT + 15) as resp:
        payload = json.loads(resp.read().decode())
    if not payload.get("ok"):
        raise RuntimeError(payload)
    return payload["result"]


def multipart_api(url, data, files):
    boundary = "----PrismBuildBot%s" % int(time.time() * 1000)
    body = bytearray()

    def add_field(name, value):
        body.extend(("--%s\r\n" % boundary).encode())
        body.extend(('Content-Disposition: form-data; name="%s"\r\n\r\n' % name).encode())
        body.extend(str(value).encode())
        body.extend(b"\r\n")

    for key, value in data.items():
        add_field(key, value)

    for field, path in files.items():
        filename = os.path.basename(path)
        body.extend(("--%s\r\n" % boundary).encode())
        body.extend(
            ('Content-Disposition: form-data; name="%s"; filename="%s"\r\n' % (field, filename)).encode()
        )
        body.extend(b"Content-Type: application/octet-stream\r\n\r\n")
        with open(path, "rb") as handle:
            body.extend(handle.read())
        body.extend(b"\r\n")

    body.extend(("--%s--\r\n" % boundary).encode())
    req = urllib.request.Request(url, data=bytes(body))
    req.add_header("Content-Type", "multipart/form-data; boundary=%s" % boundary)
    req.add_header("Content-Length", str(len(body)))
    with urllib.request.urlopen(req, timeout=600) as resp:
        payload = json.loads(resp.read().decode())
    if not payload.get("ok"):
        raise RuntimeError(payload)
    return payload["result"]


def send_message(chat_id, text, reply_markup=None):
    data = {
        "chat_id": chat_id,
        "text": text,
        "parse_mode": "HTML",
        "disable_web_page_preview": "true",
    }
    if reply_markup:
        data["reply_markup"] = json.dumps(reply_markup)
    return api("sendMessage", data)


def send_document(chat_id, path, caption):
    return api(
        "sendDocument",
        {
            "chat_id": chat_id,
            "caption": caption,
            "parse_mode": "HTML",
            "disable_web_page_preview": "true",
        },
        {"document": path},
    )


def edit_message(chat_id, message_id, text, reply_markup=None):
    data = {
        "chat_id": chat_id,
        "message_id": message_id,
        "text": text,
        "parse_mode": "HTML",
        "disable_web_page_preview": "true",
    }
    if reply_markup:
        data["reply_markup"] = json.dumps(reply_markup)
    return api("editMessageText", data)


def answer_callback(callback_id, text=None):
    data = {"callback_query_id": callback_id}
    if text:
        data["text"] = text
    api("answerCallbackQuery", data)


def allowed(user):
    if not ADMIN_ID:
        return True
    return str(user.get("id")) == str(ADMIN_ID)


def keyboard(running=False):
    if running:
        return {
            "inline_keyboard": [
                [{"text": "Cancel build", "callback_data": "cancel"}],
            ]
        }
    return {
        "inline_keyboard": [
            [
                {"text": "noKSU", "callback_data": "build:noksu"},
                {"text": "KSU-Next", "callback_data": "build:ksu"},
            ],
            [{"text": "Both variants", "callback_data": "build:both"}],
        ]
    }


def human_size(path):
    size = os.path.getsize(path)
    return "%.2f MB" % (size / 1024.0 / 1024.0)


def sha256(path):
    proc = subprocess.run(["sha256sum", path], check=True, text=True, capture_output=True)
    return proc.stdout.split()[0]


def recent_zips(started_at):
    pattern = os.path.join(RELEASE_DIR, "Prism-X01BD-*-AnyKernel3.zip")
    paths = [path for path in glob.glob(pattern) if os.path.getmtime(path) > started_at]
    return sorted(paths, key=os.path.getmtime)


def build_caption(status, variant, path=None, elapsed=None):
    timestamp = time.strftime("%Y-%m-%d %H:%M:%S %Z", time.localtime())
    lines = [
        "Prism X01BD build",
        "Variant: <code>%s</code>" % variant,
        "Status: <b>%s</b>" % status,
        "Timestamp: <code>%s</code>" % timestamp,
    ]
    if elapsed is not None:
        lines.append("Duration: <code>%ss</code>" % int(elapsed))
    if path:
        lines.extend([
            "Size: <code>%s</code>" % human_size(path),
            "SHA256: <code>%s</code>" % sha256(path),
        ])
    return "\n".join(lines)


def run_build(request_chat_id, variant):
    global BUILD_PROC
    target_chat_id = OUTPUT_CHAT_ID or request_chat_id
    started = time.time()
    log_dir = os.path.join(RELEASE_DIR, "bot-logs")
    os.makedirs(log_dir, exist_ok=True)
    log_path = os.path.join(log_dir, "prism-%s-%s.log" % (variant, time.strftime("%Y%m%d-%H%M%S")))

    with BUILD_LOCK:
        if CURRENT_BUILD["running"]:
            send_message(request_chat_id, "Build masih jalan: <code>%s</code>" % CURRENT_BUILD["variant"])
            return
        CURRENT_BUILD.update({"running": True, "variant": variant, "started": started})

    build_msg = send_message(request_chat_id, "Mulai build Prism variant <code>%s</code>." % variant)

    try:
        env = os.environ.copy()
        env["VARIANT"] = variant
        env["RELEASE_DIR"] = RELEASE_DIR
        with open(log_path, "w") as log:
            proc = subprocess.Popen(
                [BUILD_SCRIPT, "all"],
                cwd=KERNEL_DIR,
                env=env,
                stdout=log,
                stderr=subprocess.STDOUT,
                text=True,
            )
        with BUILD_LOCK:
            BUILD_PROC = proc
        proc.wait()
        elapsed = time.time() - started

        if proc.returncode != 0:
            send_document(target_chat_id, log_path, build_caption("ERROR", variant, elapsed=elapsed))
            return

        zips = recent_zips(started)
        if not zips:
            send_document(target_chat_id, log_path, build_caption("SUCCESS, ZIP NOT FOUND", variant, elapsed=elapsed))
            return

        for zip_path in zips:
            send_document(target_chat_id, zip_path, build_caption("SUCCESS", variant, zip_path, elapsed))
        send_document(target_chat_id, log_path, build_caption("LOG", variant, elapsed=elapsed))
    finally:
        with BUILD_LOCK:
            CURRENT_BUILD.update({"running": False, "variant": None, "started": None})
            BUILD_PROC = None
        edit_message(request_chat_id, build_msg["message_id"],
                     "Build <code>%s</code> selesai." % variant, keyboard(False))


def cancel_build(request_chat_id):
    with BUILD_LOCK:
        if not CURRENT_BUILD["running"]:
            send_message(request_chat_id, "Gak ada build yang jalan.")
            return
        proc = BUILD_PROC

    if proc:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()

    with BUILD_LOCK:
        CURRENT_BUILD.update({"running": False, "variant": None, "started": None})

    send_message(request_chat_id, "Build dibatalkan.")


def handle_message(message):
    chat_id = message["chat"]["id"]
    user = message.get("from", {})
    text = (message.get("text") or "").strip()

    if not allowed(user):
        send_message(chat_id, "Unauthorized.")
        return

    if text.startswith("/start") or text.startswith("/help"):
        send_message(chat_id, "Prism build controller siap.", keyboard(CURRENT_BUILD["running"]))
    elif text.startswith("/build"):
        parts = text.split()
        if len(parts) > 1 and parts[1] in ("noksu", "ksu", "both"):
            threading.Thread(target=run_build, args=(chat_id, parts[1]), daemon=True).start()
        else:
            send_message(chat_id, "Pilih variant build:", keyboard(CURRENT_BUILD["running"]))
    elif text.startswith("/cancel"):
        cancel_build(chat_id)
    elif text.startswith("/status"):
        if CURRENT_BUILD["running"]:
            send_message(chat_id, "Build jalan: <code>%s</code>" % CURRENT_BUILD["variant"])
        else:
            send_message(chat_id, "Idle.", keyboard(False))
    else:
        send_message(chat_id, "Prism build controller siap.", keyboard(CURRENT_BUILD["running"]))


def handle_callback(callback):
    global BUILD_PROC
    user = callback.get("from", {})
    message = callback.get("message", {})
    chat_id = message.get("chat", {}).get("id")
    msg_id = message.get("message_id")
    data = callback.get("data", "")

    if not chat_id:
        return
    if not allowed(user):
        answer_callback(callback["id"], "Unauthorized")
        return

    if data == "cancel":
        answer_callback(callback["id"], "Cancelling...")
        cancel_build(chat_id)
        return

    if data.startswith("build:"):
        variant = data.split(":", 1)[1]
        answer_callback(callback["id"], "Build %s queued" % variant)
        threading.Thread(target=run_build, args=(chat_id, variant), daemon=True).start()


def set_bot_commands():
    try:
        api("setMyCommands", {"commands": json.dumps(COMMANDS)})
        print("Bot commands registered.")
    except Exception as exc:
        print("Failed to register commands: %s" % exc, file=sys.stderr)


def main():
    set_bot_commands()
    offset = None
    while True:
        try:
            data = {"timeout": POLL_TIMEOUT}
            if offset is not None:
                data["offset"] = offset
            updates = api("getUpdates", data)
            for update in updates:
                offset = update["update_id"] + 1
                if "message" in update:
                    handle_message(update["message"])
                elif "callback_query" in update:
                    handle_callback(update["callback_query"])
        except (urllib.error.URLError, RuntimeError, subprocess.SubprocessError) as exc:
            print("poll error: %s" % exc, file=sys.stderr)
            time.sleep(5)


if __name__ == "__main__":
    main()
