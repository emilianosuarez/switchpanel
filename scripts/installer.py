#!/usr/bin/python3
"""Install or uninstall Switchpanel's hooks, status line and slash commands.

    installer.py install   [--config-dir DIR]... [--link] [--language auto|en|es]
                           [--summaries on|off] [--statusline] [--yes] [--dry-run]
    installer.py uninstall [--config-dir DIR]... [--purge] [--yes] [--dry-run]

Every settings.json it touches is backed up first (settings.json.switchpanel-backup-<time>).
What it changed is recorded in ~/.switchpanel/install.json so uninstall can revert exactly that.
"""
import argparse
import glob
import json
import os
import re
import shlex
import shutil
import sys
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOME = os.path.expanduser("~")
BOARD_DIR = os.environ.get("SWITCHPANEL_DIR", os.path.join(HOME, ".switchpanel"))
MANIFEST_PATH = os.path.join(BOARD_DIR, "install.json")
CONFIG_PATH = os.path.join(BOARD_DIR, "config.json")

EVENTS = ["SessionStart", "UserPromptSubmit", "PostToolUse", "Notification", "Stop", "SessionEnd"]
TITLE_ENV = "CLAUDE_CODE_DISABLE_TERMINAL_TITLE"
COMMAND_NAMES = ["label.md", "project.md", "proyecto.md"]
# board.py: nombre del hook antes de llamarse Switchpanel.
OURS = re.compile(r"(?:switchpanel|board)\.py['\"]?\s+(?:%s)\s*$" % "|".join(EVENTS + ["statusline"]))


# ---------------------------------------------------------------- helpers

def read_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        return default


def write_json(path, data, dry_run):
    if dry_run:
        return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = "%s.%d.tmp" % (path, os.getpid())
    with open(tmp, "w") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(tmp, path)


def is_ours(command):
    return bool(command) and bool(OURS.search(command))


def python_path():
    if os.path.exists("/usr/bin/python3"):
        return "/usr/bin/python3"
    return shutil.which("python3") or sys.executable


def system_language():
    import plistlib
    try:
        with open(os.path.join(HOME, "Library/Preferences/.GlobalPreferences.plist"), "rb") as f:
            langs = plistlib.load(f).get("AppleLanguages") or []
    except (OSError, ValueError):
        langs = []
    first = (langs[0] if langs else os.environ.get("LANG", ""))[:2].lower()
    return first if first in ("en", "es") else "en"


def detect_config_dirs():
    """~/.claude, $CLAUDE_CONFIG_DIR and any ~/.claude-* folder that looks like a Claude Code config."""
    found = []
    candidates = [os.path.join(HOME, ".claude"), os.environ.get("CLAUDE_CONFIG_DIR")]
    candidates += sorted(glob.glob(os.path.join(HOME, ".claude-*")))
    for d in candidates:
        if not d:
            continue
        d = os.path.normpath(os.path.expanduser(d))
        if d in found or d == os.path.normpath(BOARD_DIR) or not os.path.isdir(d):
            continue
        markers = ["settings.json", "projects", ".credentials.json", "CLAUDE.md"]
        if d != os.path.join(HOME, ".claude") and not any(os.path.exists(os.path.join(d, m)) for m in markers):
            continue
        found.append(d)
    return found


def confirm(question, assume_yes):
    if assume_yes or not sys.stdin.isatty():
        return True
    return input("%s [Y/n] " % question).strip().lower() in ("", "y", "yes", "s", "si", "sí")


def backup(path, dry_run):
    if os.path.exists(path) and not dry_run:
        shutil.copy2(path, "%s.switchpanel-backup-%s" % (path, time.strftime("%Y%m%d-%H%M%S")))


def strip_our_hooks(settings):
    """Removes our hook entries, keeping everything else (and dropping groups/events left empty)."""
    hooks = settings.get("hooks")
    if not isinstance(hooks, dict):
        return
    for event in list(hooks):
        groups = []
        for group in hooks[event] or []:
            inner = [h for h in group.get("hooks", []) if not is_ours(h.get("command"))]
            if inner:
                groups.append(dict(group, hooks=inner))
            elif not group.get("hooks"):
                groups.append(group)
        if groups:
            hooks[event] = groups
        else:
            del hooks[event]
    if not hooks:
        del settings["hooks"]


def looks_like_our_command(path):
    try:
        with open(path) as f:
            text = f.read()
        return "Switchpanel" in text or "Claude Board" in text  # nombre anterior
    except OSError:
        return False


# ---------------------------------------------------------------- install

def install_dir(config_dir, board_cmd, lang, args, previous):
    settings_path = os.path.join(config_dir, "settings.json")
    try:
        settings = read_json(settings_path, {})
    except ValueError as e:
        print("  ✗ %s is not valid JSON (%s); skipped" % (settings_path, e))
        return None
    record = {"statusline_prev": previous.get("statusline_prev"),
              "added_env": previous.get("added_env", False),
              "commands": []}

    strip_our_hooks(settings)
    hooks = settings.setdefault("hooks", {})
    for event in EVENTS:
        hooks.setdefault(event, []).append(
            {"hooks": [{"type": "command", "command": "%s %s" % (board_cmd, event), "timeout": 10}]})
    print("  ✓ hooks: %s" % ", ".join(EVENTS))

    current = settings.get("statusLine")
    ours = {"type": "command", "command": "%s statusline" % board_cmd, "padding": 0}
    if current is None or is_ours((current or {}).get("command")):
        settings["statusLine"] = ours
        print("  ✓ status line")
    elif args.statusline:
        record["statusline_prev"] = current
        settings["statusLine"] = ours
        print("  ✓ status line (yours was saved and comes back on uninstall)")
    else:
        print("  • status line: you already have one, left as is (use --statusline to replace it)")

    env = settings.setdefault("env", {})
    if env.get(TITLE_ENV) is None:
        env[TITLE_ENV] = "1"
        record["added_env"] = True
    print("  ✓ env %s=1 (so Claude Code doesn't overwrite the tab title)" % TITLE_ENV)

    commands_dir = os.path.join(config_dir, "commands")
    wanted = sorted(os.listdir(os.path.join(REPO, "commands", lang)))
    for name in COMMAND_NAMES:
        dest = os.path.join(commands_dir, name)
        ours_before = name in previous.get("commands", []) or looks_like_our_command(dest)
        if name not in wanted:
            if os.path.exists(dest) and ours_before and not args.dry_run:
                os.remove(dest)
            continue
        if os.path.exists(dest) and not ours_before:
            print("  • /%s: you already have a command with that name, left as is" % name[:-3])
            continue
        if not args.dry_run:
            os.makedirs(commands_dir, exist_ok=True)
            shutil.copyfile(os.path.join(REPO, "commands", lang, name), dest)
        record["commands"].append(name)
    print("  ✓ commands: %s" % " ".join("/" + n[:-3] for n in record["commands"]))

    backup(settings_path, args.dry_run)
    write_json(settings_path, settings, args.dry_run)
    return record


def install(args):
    dirs = [os.path.normpath(os.path.expanduser(d)) for d in args.config_dir] or detect_config_dirs()
    if not dirs:
        print("No Claude Code config folder found (~/.claude). Run Claude Code once, or pass --config-dir.")
        return 1
    print("Claude Code config folders:\n  " + "\n  ".join(dirs))
    if not confirm("Install Switchpanel hooks into these?", args.yes):
        return 1

    if args.link:
        board_path = os.path.join(REPO, "hooks", "switchpanel.py")
    else:
        board_path = os.path.join(BOARD_DIR, "bin", "switchpanel.py")
        if not args.dry_run:
            os.makedirs(os.path.dirname(board_path), exist_ok=True)
            shutil.copyfile(os.path.join(REPO, "hooks", "switchpanel.py"), board_path)
            os.chmod(board_path, 0o755)
    board_cmd = "%s %s" % (python_path(), shlex.quote(board_path))

    config = read_json(CONFIG_PATH, {})
    if args.language:
        config["language"] = args.language
    if args.summaries:
        config.setdefault("summaries", {"model": "haiku"})["enabled"] = args.summaries == "on"
    lang = config.get("language") or "auto"
    lang = system_language() if lang == "auto" else lang
    lang = lang if lang in ("en", "es") else "en"

    manifest = read_json(MANIFEST_PATH, {})
    manifest.setdefault("config_dirs", {})
    for d in dirs:
        print("\n%s" % d)
        record = install_dir(d, board_cmd, lang, args, manifest["config_dirs"].get(d, {}))
        if record is not None:
            manifest["config_dirs"][d] = record
    manifest.update({"board_path": board_path, "linked": args.link, "installed_at": time.strftime("%Y-%m-%dT%H:%M:%S%z")})
    write_json(MANIFEST_PATH, manifest, args.dry_run)
    if args.language or args.summaries:
        write_json(CONFIG_PATH, config, args.dry_run)

    print("\nDone%s. Restart your Claude Code sessions to pick up the hooks." % (" (dry run, nothing written)" if args.dry_run else ""))
    if not (config.get("summaries") or {}).get("enabled"):
        print("Summaries are off. They run `claude -p --model haiku` after each turn and use your plan's quota;"
              "\nturn them on with --summaries on or \"summaries\": {\"enabled\": true} in %s" % CONFIG_PATH)
    return 0


# -------------------------------------------------------------- uninstall

def uninstall(args):
    manifest = read_json(MANIFEST_PATH, {})
    recorded = manifest.get("config_dirs", {})
    dirs = [os.path.normpath(os.path.expanduser(d)) for d in args.config_dir]
    if not dirs:
        dirs = list(recorded) + [d for d in detect_config_dirs() if d not in recorded]
    print("Claude Code config folders:\n  " + "\n  ".join(dirs))
    if not confirm("Remove Switchpanel from these?", args.yes):
        return 1

    for d in dirs:
        record = recorded.get(d, {})
        print("\n%s" % d)
        settings_path = os.path.join(d, "settings.json")
        try:
            settings = read_json(settings_path, None)
        except ValueError as e:
            print("  ✗ %s is not valid JSON (%s); skipped" % (settings_path, e))
            continue
        if settings is not None:
            strip_our_hooks(settings)
            if is_ours((settings.get("statusLine") or {}).get("command")):
                if record.get("statusline_prev"):
                    settings["statusLine"] = record["statusline_prev"]
                else:
                    del settings["statusLine"]
            env = settings.get("env")
            if record.get("added_env") and isinstance(env, dict):
                env.pop(TITLE_ENV, None)
                if not env:
                    del settings["env"]
            backup(settings_path, args.dry_run)
            write_json(settings_path, settings, args.dry_run)
            print("  ✓ hooks and status line removed")
        removed = []
        for name in COMMAND_NAMES:
            dest = os.path.join(d, "commands", name)
            if os.path.exists(dest) and (name in record.get("commands", []) or looks_like_our_command(dest)):
                if not args.dry_run:
                    os.remove(dest)
                removed.append("/" + name[:-3])
        if removed:
            print("  ✓ commands removed: %s" % " ".join(removed))

    if not args.dry_run:
        shutil.rmtree(os.path.join(BOARD_DIR, "bin"), ignore_errors=True)
        if args.purge:
            shutil.rmtree(BOARD_DIR, ignore_errors=True)
        elif os.path.exists(MANIFEST_PATH):
            os.remove(MANIFEST_PATH)
    print("\nDone%s." % (" (dry run, nothing written)" if args.dry_run else ""))
    if not args.purge:
        print("Your data and config are still in %s (use --purge to delete them)." % BOARD_DIR)
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="action", required=True)
    for name in ("install", "uninstall"):
        p = sub.add_parser(name)
        p.add_argument("--config-dir", action="append", default=[], metavar="DIR",
                       help="Claude Code config folder (repeatable). Default: detect ~/.claude and ~/.claude-*")
        p.add_argument("--yes", "-y", action="store_true", help="don't ask for confirmation")
        p.add_argument("--dry-run", action="store_true", help="show what would change without writing")
    p = sub.choices["install"]
    p.add_argument("--link", action="store_true", help="run the hook from this repo instead of a copy (for development)")
    p.add_argument("--language", choices=["auto", "en", "es"], help="language for the hook and the app")
    p.add_argument("--summaries", choices=["on", "off"], help="session summaries with Haiku (uses your plan)")
    p.add_argument("--statusline", action="store_true", help="replace an existing status line")
    sub.choices["uninstall"].add_argument("--purge", action="store_true", help="also delete ~/.switchpanel")
    args = parser.parse_args()
    sys.exit(install(args) if args.action == "install" else uninstall(args))


if __name__ == "__main__":
    main()
