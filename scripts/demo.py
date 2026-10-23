#!/usr/bin/python3
"""Opens Switchpanel with made-up sessions, for screenshots.

    scripts/demo.py [--language en|es]

Quits the running app, writes demo data to a temporary folder and opens the app on it
(SWITCHPANEL_DIR). Your real data isn't touched. To go back: quit the demo from the
menu bar and open ~/Applications/Switchpanel.app again.
"""
import argparse
import json
import os
import subprocess
import tempfile
import time

APP = os.path.expanduser("~/Applications/Switchpanel.app")


def ago(minutes):
    return time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(time.time() - minutes * 60))


def project(name):
    return "/Users/demo/code/" + name


CONFIG = {
    "accounts": {
        ".claude": {"name": "Work", "emoji": "🏢", "color": "blue"},
        ".claude-personal": {"name": "Personal", "emoji": "🏠", "color": "green"},
    },
    "projects": {
        project("shop-api"): {"name": "shop-api", "color": "orange"},
        project("web-dashboard"): {"name": "web-dashboard", "color": "purple"},
        project("mobile-app"): {"name": "mobile-app", "color": "teal"},
        project("blog"): {"name": "blog", "color": "pink"},
        project("dotfiles"): {"name": "dotfiles", "color": "yellow"},
    },
    "summaries": {"enabled": False},
}

# (account, project, status, minutes ago, title, summary or None)
SESSIONS = [
    (".claude", "shop-api", "waiting_permission", 6, "Fix N+1 query in orders", {
        "text": "Added eager loading to the orders endpoint; about to run the full test suite.",
        "next_steps": ["Run the test suite", "Compare query counts before and after"],
    }),
    (".claude", "web-dashboard", "done", 2, "Revenue chart", {
        "text": "Built the revenue chart with a date range picker.",
        "next_steps": ["Pick the default range", "Add an empty state"],
        "waiting_for": "Should the chart default to the last 7 or the last 30 days?",
    }),
    (".claude", "shop-api", "working", 1, "Add rate limiting", None),
    (".claude", "mobile-app", "done", 14, "Dark mode for settings", {
        "text": "Settings screen now follows the system theme; snapshots updated.",
        "next_steps": ["Review contrast on the toggle rows", "Open a PR"],
    }),
    (".claude-personal", "blog", "working", 4, "Migrate to Astro 5", None),
    (".claude-personal", "dotfiles", "idle", 32, "zsh prompt tweaks", None),
]


def write_demo(folder, language):
    os.makedirs(os.path.join(folder, "sessions"), exist_ok=True)
    with open(os.path.join(folder, "config.json"), "w") as f:
        json.dump(dict(CONFIG, language=language), f, ensure_ascii=False, indent=2)
    for i, (account, name, status, minutes, title, summary) in enumerate(SESSIONS):
        s = {
            "session_id": "demo-%d" % i,
            "agent": "claude-code",
            "account": account,
            "project": project(name),
            "tty": "/dev/ttys9%02d" % i,
            "pid": 1,  # siempre vivo, para que la app no la oculte
            "status": status,
            "title": title,
            "turns": 3,
            "updated_at": ago(minutes),
            "prompt_at": ago(minutes),
            "done_at": ago(minutes),
        }
        if status == "waiting_permission":
            s["attention"] = "Claude needs your permission to use Bash"
            s["attention_at"] = ago(minutes)
        if summary:
            s["summary"] = dict({"task": title, "waiting_for": "", "at": ago(minutes)}, **summary)
            s["summary_turn"] = 3
        with open(os.path.join(folder, "sessions", s["session_id"] + ".json"), "w") as f:
            json.dump(s, f, ensure_ascii=False, indent=2)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--language", choices=["en", "es"], default="en")
    args = parser.parse_args()

    folder = tempfile.mkdtemp(prefix="switchpanel-demo-")
    write_demo(folder, args.language)
    subprocess.run(["pkill", "-x", "Switchpanel"])
    for _ in range(50):
        if subprocess.run(["pgrep", "-x", "Switchpanel"], capture_output=True).returncode != 0:
            break
        time.sleep(0.1)
    subprocess.run(["open", "--env", "SWITCHPANEL_DIR=" + folder, APP], check=True)
    print("Demo running with data in %s" % folder)
    print("When you're done: Quit from the menu bar, then `open %s`" % APP)


if __name__ == "__main__":
    main()
