#!/usr/bin/python3
"""Switchpanel: registra el estado de cada sesión de Claude Code.

Uso (desde hooks de Claude Code, que pasan el evento por stdin):
    switchpanel.py SessionStart | UserPromptSubmit | PostToolUse | Notification | Stop | SessionEnd
    switchpanel.py statusline            # status line de Claude Code
    switchpanel.py summarize <session>   # interno: genera el resumen con Haiku

Datos en ~/.switchpanel/:
    config.json            cuentas y proyectos (nombre, color) — editable
    sessions/<id>.json     estado de cada sesión (formato en docs/session-format.md)
"""
import fcntl
import json
import os
import plistlib
import re
import subprocess
import sys
import time
from contextlib import contextmanager

HOME = os.path.expanduser("~")
BOARD_DIR = os.environ.get("SWITCHPANEL_DIR", os.path.join(HOME, ".switchpanel"))
SESSIONS_DIR = os.path.join(BOARD_DIR, "sessions")
CONFIG_PATH = os.path.join(BOARD_DIR, "config.json")
LOG_PATH = os.path.join(BOARD_DIR, "switchpanel.log")
LOCKS_DIR = os.path.join(BOARD_DIR, "locks")

# Variable que marca las llamadas internas a `claude -p` (evita bucles de hooks).
INTERNAL_ENV = "SWITCHPANEL_INTERNAL"

# Nombre de color -> código ANSI 256 (Terminal.app no soporta truecolor) y hex (para la app).
PALETTE = {
    "blue": (33, "#2F80ED"),
    "green": (35, "#27AE60"),
    "orange": (208, "#F2994A"),
    "purple": (135, "#9B51E0"),
    "pink": (205, "#EB5CA8"),
    "teal": (44, "#2BB5C4"),
    "yellow": (220, "#F2C94C"),
    "red": (196, "#EB5757"),
    "gray": (245, "#8A8A8A"),
}

# Nombres en español (y los que usaban las configs viejas) -> nombre canónico.
COLOR_ALIASES = {
    "azul": "blue", "verde": "green", "naranja": "orange", "violeta": "purple",
    "rosa": "pink", "turquesa": "teal", "amarillo": "yellow", "rojo": "red", "gris": "gray",
    "grey": "gray", "violet": "purple", "cyan": "teal",
}

# Círculo de color para el título de la pestaña (Terminal.app no permite colorear pestañas).
DOTS = {
    "blue": "🔵", "green": "🟢", "orange": "🟠", "purple": "🟣", "pink": "🩷",
    "teal": "🩵", "yellow": "🟡", "red": "🔴", "gray": "⚪",
}

DEFAULT_CONFIG = {
    "language": "auto",
    "accounts": {},
    "projects": {},
    "summaries": {"enabled": False, "model": "haiku"},
}

LABEL_RE = re.compile(r"^\s*/label(?:\s+(.*))?$", re.S)
PROJECT_RE = re.compile(r"^\s*/(?:project|proyecto)(?:\s+(.*))?$", re.S)

MESSAGES = {
    "en": {
        "label_set": "🏷  Label: {label}",
        "label_cleared": "🏷  Label cleared",
        "no_project": "I don't know this session's project yet",
        "project_usage": "📁 {name} ({color}). Usage: /project [name] [color]. Colors: {colors}",
        "project_set": "📁 Project: {name} ({color})",
        "waiting": "  ⏳ waiting: ",
        "next": "  ↳ next: ",
        "language_name": "English",
    },
    "es": {
        "label_set": "🏷  Etiqueta: {label}",
        "label_cleared": "🏷  Etiqueta borrada",
        "no_project": "No conozco el proyecto de esta sesión todavía",
        "project_usage": "📁 {name} ({color}). Uso: /proyecto [nombre] [color]. Colores: {colors}",
        "project_set": "📁 Proyecto: {name} ({color})",
        "waiting": "  ⏳ espera: ",
        "next": "  ↳ próximo: ",
        "language_name": "Spanish",
    },
}

COLOR_NAMES_ES = {v: k for k, v in COLOR_ALIASES.items() if k in
                  ("azul", "verde", "naranja", "violeta", "rosa", "turquesa", "amarillo", "rojo", "gris")}


# ---------------------------------------------------------------- utilidades

def log(msg):
    try:
        with open(LOG_PATH, "a") as f:
            f.write("%s %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg))
    except OSError:
        pass


def now():
    return time.strftime("%Y-%m-%dT%H:%M:%S%z")


def read_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def write_json(path, data):
    tmp = "%s.%d.tmp" % (path, os.getpid())
    with open(tmp, "w") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    os.replace(tmp, path)


@contextmanager
def locked(name):
    os.makedirs(LOCKS_DIR, exist_ok=True)
    with open(os.path.join(LOCKS_DIR, "%s.lock" % name), "w") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(f, fcntl.LOCK_UN)


def load_config():
    cfg = read_json(CONFIG_PATH, None)
    if cfg is None:
        cfg = json.loads(json.dumps(DEFAULT_CONFIG))
        os.makedirs(BOARD_DIR, exist_ok=True)
        write_json(CONFIG_PATH, cfg)
    for key, value in DEFAULT_CONFIG.items():
        cfg.setdefault(key, json.loads(json.dumps(value)))
    for entry in list(cfg["accounts"].values()) + list(cfg["projects"].values()):
        if isinstance(entry, dict) and entry.get("color") in COLOR_ALIASES:
            entry["color"] = COLOR_ALIASES[entry["color"]]
    return cfg


def color_name(name):
    """Nombre canónico de un color escrito en inglés o en español; None si no es un color."""
    name = (name or "").lower()
    name = COLOR_ALIASES.get(name, name)
    return name if name in PALETTE else None


_system_language = None


def system_language():
    """Idioma preferido de macOS (AppleLanguages), o de LANG si no se puede leer."""
    global _system_language
    if _system_language is None:
        langs = []
        try:
            with open(os.path.join(HOME, "Library/Preferences/.GlobalPreferences.plist"), "rb") as f:
                langs = plistlib.load(f).get("AppleLanguages") or []
        except (OSError, ValueError, plistlib.InvalidFileException):
            pass
        first = langs[0] if langs else os.environ.get("LANG", "")
        _system_language = first[:2].lower()
    return _system_language


def language(cfg=None):
    lang = (cfg or load_config()).get("language") or "auto"
    if lang == "auto":
        lang = system_language()
    return lang if lang in MESSAGES else "en"


def t(key, cfg=None, **kwargs):
    return MESSAGES[language(cfg)][key].format(**kwargs)


def display_color(name, cfg=None):
    return COLOR_NAMES_ES.get(name, name) if language(cfg) == "es" else name


def account_key():
    config_dir = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(HOME, ".claude")
    return os.path.basename(os.path.normpath(config_dir)), config_dir


def ensure_account(key):
    """Registra una cuenta nueva (por carpeta de config) con nombre derivado: .claude-work -> Work."""
    with locked("config"):
        cfg = load_config()
        if key not in cfg["accounts"]:
            name = key[len(".claude-"):] if key.startswith(".claude-") else key.lstrip(".")
            cfg["accounts"][key] = {"name": name.capitalize() or key, "emoji": "👤", "color": "gray"}
            write_json(CONFIG_PATH, cfg)


def project_root(cwd):
    try:
        out = subprocess.run(
            ["git", "-C", cwd, "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=3,
        )
        if out.returncode == 0 and out.stdout.strip():
            return out.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        pass
    return cwd


def ensure_project(path):
    """Devuelve la config del proyecto; si es nuevo le asigna un color libre."""
    with locked("config"):
        cfg = load_config()
        projects = cfg["projects"]
        if path not in projects:
            used = [p.get("color") for p in projects.values()]
            names = [c for c in PALETTE if c != "gray"]
            color = min(names, key=lambda c: (used.count(c), names.index(c)))
            projects[path] = {"name": os.path.basename(path) or path, "color": color}
            write_json(CONFIG_PATH, cfg)
        return projects[path]


def find_tty():
    """Sube por los procesos padres hasta encontrar la terminal (tty) de la sesión."""
    pid = os.getppid()
    for _ in range(8):
        try:
            out = subprocess.run(
                ["ps", "-o", "ppid=,tty=", "-p", str(pid)],
                capture_output=True, text=True, timeout=2,
            ).stdout.split()
        except (OSError, subprocess.SubprocessError):
            return None, None
        if len(out) < 2:
            return None, None
        ppid, tty = out[0], out[1]
        if tty not in ("??", "-"):
            return "/dev/" + tty, pid
        pid = int(ppid)
    return None, None


def session_path(session_id):
    return os.path.join(SESSIONS_DIR, "%s.json" % session_id)


@contextmanager
def session(session_id):
    """Lee, deja modificar y guarda la sesión con lock."""
    with locked(session_id):
        path = session_path(session_id)
        data = read_json(path, {"session_id": session_id})
        yield data
        data["updated_at"] = now()
        write_json(path, data)


def transcript_info(path, tail_bytes=400000):
    """Título automático (ai-title) y último mensaje de Claude, leyendo el final del transcript."""
    title, last_text = None, None
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            size = f.tell()
            f.seek(max(0, size - tail_bytes))
            lines = f.read().decode("utf-8", "replace").splitlines()
    except OSError:
        return None, None
    for line in reversed(lines):
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if title is None and entry.get("type") in ("custom-title", "ai-title"):
            title = entry.get("customTitle") or entry.get("aiTitle")
        if last_text is None and entry.get("type") == "assistant":
            texts = [c.get("text", "") for c in entry.get("message", {}).get("content", [])
                     if isinstance(c, dict) and c.get("type") == "text"]
            if any(t.strip() for t in texts):
                last_text = "\n".join(texts).strip()
        if title and last_text:
            break
    return title, last_text


def block(reason):
    print(json.dumps({"decision": "block", "reason": reason}, ensure_ascii=False))
    sys.exit(0)


# ------------------------------------------------------------------- eventos

def on_session_start(ev, s):
    key, config_dir = account_key()
    cwd = ev.get("cwd") or os.getcwd()
    root = project_root(cwd)
    ensure_account(key)
    ensure_project(root)
    tty, pid = find_tty()
    s.update({
        "agent": "claude-code",
        "account": key,
        "config_dir": config_dir,
        "cwd": cwd,
        "project": root,
        "transcript_path": ev.get("transcript_path"),
        "tty": tty or s.get("tty"),
        "pid": pid or s.get("pid"),
        "status": "idle",
        "attention": None,
    })
    s.setdefault("started_at", now())
    s.setdefault("label", None)
    s.setdefault("turns", 0)
    title, _ = transcript_info(ev.get("transcript_path") or "")
    if title:
        s["title"] = title


def on_prompt(ev, s):
    prompt = ev.get("prompt") or ""

    m = LABEL_RE.match(prompt)
    if m:
        label = (m.group(1) or "").strip() or None
        s["label"] = label
        return t("label_set", label=label) if label else t("label_cleared")

    m = PROJECT_RE.match(prompt)
    if m:
        return set_project(s, (m.group(1) or "").strip())

    s["status"] = "working"
    s["attention"] = None
    s["last_prompt"] = prompt.strip()[:400]
    s["prompt_at"] = now()
    return None


def set_project(s, args):
    """/project (o /proyecto) [nombre] [color] — renombra o recolorea el proyecto de esta sesión."""
    root = s.get("project")
    if not root:
        return t("no_project")
    with locked("config"):
        cfg = load_config()
        proj = cfg["projects"].setdefault(root, {"name": os.path.basename(root), "color": "gray"})
        words = args.split()
        if words and color_name(words[-1]):
            proj["color"] = color_name(words.pop())
        if words:
            proj["name"] = " ".join(words)
        color = display_color(proj.get("color"), cfg)
        if not args:
            colors = ", ".join(display_color(c, cfg) for c in PALETTE)
            return t("project_usage", cfg, name=proj["name"], color=color, colors=colors)
        write_json(CONFIG_PATH, cfg)
        return t("project_set", cfg, name=proj["name"], color=color)


def on_post_tool(ev, s):
    if s.get("status") != "working":
        s["status"] = "working"
        s["attention"] = None


def on_notification(ev, s):
    kind = ev.get("notification_type") or ""
    msg = ev.get("message") or ""
    if kind == "idle_prompt" or "waiting for your input" in msg:
        if s.get("status") != "done":
            s["status"] = "waiting_input"
    else:
        s["status"] = "waiting_permission"
        s["attention"] = msg[:300]
    s["attention_at"] = now()


def on_stop(ev, s):
    s["status"] = "done"
    s["attention"] = None
    s["turns"] = s.get("turns", 0) + 1
    s["done_at"] = now()
    title, last_text = transcript_info(ev.get("transcript_path") or s.get("transcript_path") or "")
    if title:
        s["title"] = title
    if last_text:
        s["last_message"] = last_text[-1500:]
    return True


def on_session_end(ev, s):
    s["status"] = "ended"
    s["ended_reason"] = ev.get("reason")
    s["ended_at"] = now()


HANDLERS = {
    "SessionStart": on_session_start,
    "UserPromptSubmit": on_prompt,
    "PostToolUse": on_post_tool,
    "Notification": on_notification,
    "Stop": on_stop,
    "SessionEnd": on_session_end,
}


def handle_event(name):
    ev = json.loads(sys.stdin.read() or "{}")
    sid = ev.get("session_id")
    if not sid:
        return
    with session(sid) as s:
        if "account" not in s and name != "SessionStart":
            # Sesión iniciada antes de instalar los hooks: la registramos ahora.
            on_session_start(ev, s)
        result = HANDLERS[name](ev, s)
    set_terminal_title(s)
    if name == "UserPromptSubmit" and result:
        block(result)
    if name == "Stop" and load_config()["summaries"].get("enabled", True):
        spawn_summary(sid)


# ------------------------------------------------------------------ resumen

def spawn_summary(sid):
    subprocess.Popen(
        [sys.executable, os.path.abspath(__file__), "summarize", sid],
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        start_new_session=True,
    )


def conversation_excerpt(path, max_chars=14000):
    """Mensajes de texto de usuario y Claude (sin herramientas), los más recientes."""
    parts = []
    try:
        with open(path) as f:
            lines = f.readlines()
    except OSError:
        return ""
    for line in lines:
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        kind = entry.get("type")
        if kind not in ("user", "assistant") or entry.get("isMeta") or entry.get("isSidechain"):
            continue
        content = entry.get("message", {}).get("content")
        if isinstance(content, str):
            texts = [content]
        else:
            texts = [c.get("text", "") for c in content or []
                     if isinstance(c, dict) and c.get("type") == "text"]
        text = "\n".join(t for t in texts if t.strip()).strip()
        if not text or text.startswith("<"):
            continue
        who = "USER" if kind == "user" else "CLAUDE"
        parts.append("%s: %s" % (who, text[:2500]))
    out, total = [], 0
    for p in reversed(parts):
        if total + len(p) > max_chars:
            break
        out.append(p)
        total += len(p)
    return "\n\n".join(reversed(out))


SUMMARY_PROMPT = """You summarize coding sessions so the developer can pick up the context quickly.
Below is the end of a conversation between the USER and CLAUDE (a coding agent).

Reply ONLY with a JSON object, with no surrounding text or code fences, shaped like this:
{"task": "what is being worked on, max 8 words",
 "summary": "what was done and where it stands, 1-2 sentences",
 "next_steps": ["concrete step", "..."],
 "waiting_for": "the specific decision or answer Claude is waiting for from the user, or an empty string if none"}

Write the values in %s. Be concise, at most 3 next steps.

<conversation>
%s
</conversation>"""


def extract_json(text):
    m = re.search(r"\{.*\}", text or "", re.S)
    if not m:
        return None
    try:
        return json.loads(m.group(0))
    except ValueError:
        return None


def summarize(sid):
    s = read_json(session_path(sid), None)
    if not s or not s.get("transcript_path"):
        return
    turn = s.get("turns", 0)
    if s.get("summary_turn") == turn:
        return
    # Un solo resumen por sesión a la vez; el próximo Stop retoma si quedó atrasado.
    lock_path = os.path.join(LOCKS_DIR, "summary-%s.lock" % sid)
    lock = open(lock_path, "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return
    try:
        excerpt = conversation_excerpt(s["transcript_path"])
        if not excerpt:
            return
        cfg = load_config()
        model = cfg["summaries"].get("model", "haiku")
        env = dict(os.environ)
        env[INTERNAL_ENV] = "1"
        # Sin API key: usa el login (plan) de la misma cuenta que la sesión.
        env.pop("ANTHROPIC_API_KEY", None)
        # La cuenta por defecto (~/.claude) debe correr SIN CLAUDE_CONFIG_DIR: si se define,
        # Claude Code busca otra credencial en el llavero y responde "Not logged in".
        default_dir = os.path.join(HOME, ".claude")
        if not s.get("config_dir") or os.path.normpath(s["config_dir"]) == default_dir:
            env.pop("CLAUDE_CONFIG_DIR", None)
        else:
            env["CLAUDE_CONFIG_DIR"] = s["config_dir"]
        proc = subprocess.run(
            ["claude", "-p", "--model", model, "--no-session-persistence",
             "--tools", "", "--strict-mcp-config", "--output-format", "json"],
            input=SUMMARY_PROMPT % (t("language_name", cfg), excerpt), capture_output=True, text=True,
            timeout=120, cwd=BOARD_DIR, env=env,
        )
        result = (extract_json(proc.stdout) or {}).get("result")
        data = extract_json(result)
        if not data:
            log("summary %s falló: rc=%s %s %s" % (sid, proc.returncode, proc.stdout[-300:], proc.stderr[-300:]))
            return
        with session(sid) as cur:
            # Acepta también las claves en español del prompt anterior.
            cur["summary"] = {
                "task": data.get("task") or data.get("tarea") or "",
                "text": data.get("summary") or data.get("resumen") or "",
                "next_steps": data.get("next_steps") or data.get("proximos_pasos") or [],
                "waiting_for": data.get("waiting_for") or data.get("esperando") or "",
                "at": now(),
            }
            cur["summary_turn"] = turn
        set_terminal_title(cur)
    except (OSError, subprocess.SubprocessError) as e:
        log("summary %s error: %s" % (sid, e))
    finally:
        fcntl.flock(lock, fcntl.LOCK_UN)
        lock.close()


# ------------------------------------------------------- título de pestaña

def state_symbol(s):
    """Estado que persiste en la pestaña hasta que respondés (a diferencia de la campanita)."""
    status = s.get("status")
    if status == "working":
        return "⚙️"
    if status == "waiting_permission":
        return "⏳"
    if status in ("done", "waiting_input"):
        waiting = (s.get("summary") or {}).get("waiting_for")
        if waiting and s.get("summary_turn") == s.get("turns"):
            return "⏳"
        return "✅"
    return ""


def short(text, n):
    text = (text or "").strip()
    return text if len(text) <= n else text[:n - 1].rstrip() + "…"


def set_terminal_title(s, cfg=None):
    """Escribe el título directo en la tty de la sesión.

    Terminal.app usa un único título (OSC 0) para la pestaña y la ventana, así que va el corto.
    """
    tty = s.get("tty")
    if not tty or not s.get("project"):
        return
    cfg = cfg or load_config()
    proj = cfg["projects"].get(s["project"], {"name": os.path.basename(s["project"]), "color": "gray"})
    dot = DOTS.get(color_name(proj.get("color")), "⚪")
    name = proj.get("short") or short(proj["name"], 10)
    task = s.get("label") or s.get("title") or (s.get("summary") or {}).get("task") or ""

    if s.get("status") == "ended":
        title = "%s %s" % (dot, name)
    else:
        title = "%s%s %s %s" % (dot, state_symbol(s), name, short(task, 14))
    try:
        fd = os.open(tty, os.O_WRONLY | os.O_NOCTTY | os.O_NONBLOCK)
        try:
            os.write(fd, ("\033]0;%s\007" % title.strip()).encode("utf-8"))
        finally:
            os.close(fd)
    except OSError:
        pass


# --------------------------------------------------------------- statusline

def ansi(color, text, bold=False):
    code = PALETTE.get(color_name(color), PALETTE["gray"])[0]
    return "\033[%s38;5;%dm%s\033[0m" % ("1;" if bold else "", code, text)


def gray(text, code=250):
    """Gris claro legible sobre fondo oscuro (el modo "dim" de Terminal.app queda casi invisible)."""
    return "\033[38;5;%dm%s\033[0m" % (code, text)


def statusline():
    ev = json.loads(sys.stdin.read() or "{}")
    cfg = load_config()
    s = read_json(session_path(ev.get("session_id", "")), {})
    set_terminal_title(s, cfg)  # se refresca seguido: recupera el título si algo lo pisó
    key = s.get("account") or account_key()[0]
    acc = cfg["accounts"].get(key, {"name": key, "emoji": "•", "color": "gray"})
    root = s.get("project") or (ev.get("workspace") or {}).get("project_dir") or ev.get("cwd") or ""
    proj = cfg["projects"].get(root, {"name": os.path.basename(root), "color": "gray"})
    task = s.get("label") or s.get("title") or (s.get("summary") or {}).get("task") or ""
    model = (ev.get("model") or {}).get("display_name", "")

    line = "%s %s" % (acc.get("emoji", ""), ansi(proj["color"], "● " + proj["name"], bold=True))
    if task:
        line += " · " + task
    if model:
        line += gray("  │ %s" % model, 244)
    lines = [line]

    summary = s.get("summary") or {}
    if summary.get("waiting_for"):
        lines.append(ansi("yellow", t("waiting", cfg), bold=True) + gray(summary["waiting_for"][:140]))
    elif summary.get("next_steps"):
        lines.append(ansi("teal", t("next", cfg), bold=True) + gray(summary["next_steps"][0][:140]))
    print("\n".join(lines))


# ------------------------------------------------------------------- main

def main():
    if os.environ.get(INTERNAL_ENV):
        return
    if len(sys.argv) < 2:
        print(__doc__)
        return
    cmd = sys.argv[1]
    os.makedirs(SESSIONS_DIR, exist_ok=True)
    try:
        if cmd in HANDLERS:
            handle_event(cmd)
        elif cmd == "statusline":
            statusline()
        elif cmd == "summarize" and len(sys.argv) > 2:
            os.makedirs(LOCKS_DIR, exist_ok=True)
            summarize(sys.argv[2])
    except SystemExit:
        raise
    except Exception as e:  # un hook roto nunca debe trabar a Claude Code
        log("%s error: %r" % (cmd, e))


if __name__ == "__main__":
    main()
