#!/usr/bin/env bash
# Installer for claude-usage-emailer on macOS and Linux (including Raspberry Pi).
# Safe to run more than once. Run with --uninstall to remove it.
#
# Optional environment variables:
#   INSTALL_DIR    where to install           (default ~/claude-usage-emailer)
#   SEND_HOUR      hour to send, 0-23         (default 8)
#   SEND_MINUTE    minute to send, 0-59       (default 0)
#   SCHEDULER      Linux only: cron (default) or systemd
#   SMTP_HOST SMTP_PORT SMTP_FROM SMTP_USERNAME SMTP_PASSWORD
#                  fill the smtp section of config.json without editing it by hand
set -euo pipefail

OS="$(uname)"
case "$OS" in
  Darwin|Linux) ;;
  *) echo "Unsupported system: $OS. On Windows use setup.ps1."; exit 1 ;;
esac

SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="${INSTALL_DIR:-$HOME/claude-usage-emailer}"
HOUR=$((10#${SEND_HOUR:-8}))
MINUTE=$((10#${SEND_MINUTE:-0}))
LABEL="com.github.claude-usage-emailer"
UNIT="claude-usage-emailer"
SCHEDULER="${SCHEDULER:-cron}"

if [ "${1:-}" = "--uninstall" ]; then
  if [ "$OS" = "Darwin" ]; then
    launchctl unload "$HOME/Library/LaunchAgents/$LABEL.plist" 2>/dev/null || true
    rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
  else
    if command -v crontab >/dev/null; then
      { crontab -l 2>/dev/null | grep -v '# claude-usage-emailer' || true; } | crontab -
    fi
    if command -v systemctl >/dev/null; then
      systemctl --user disable --now "$UNIT.timer" 2>/dev/null || true
      rm -f "$HOME/.config/systemd/user/$UNIT.service" "$HOME/.config/systemd/user/$UNIT.timer"
      systemctl --user daemon-reload 2>/dev/null || true
    fi
  fi
  echo "Schedule removed. Delete $DEST yourself if you no longer need the config or logs."
  exit 0
fi
PY="$(command -v python3 || true)"
if [ -z "$PY" ]; then
  if [ "$OS" = "Darwin" ]; then echo "python3 not found. Run: xcode-select --install"
  else echo "python3 not found. Install it with your package manager, e.g. sudo apt install python3"; fi
  exit 1
fi

# 1. Copy files. On macOS keep this outside Documents/Desktop/Downloads,
#    because macOS stops background jobs reading those folders.
mkdir -p "$DEST"
if [ "$SRC" != "$DEST" ]; then
  for f in usage_report.py config.example.json README.md AGENT_SETUP.md setup.sh; do
    [ -f "$SRC/$f" ] && cp "$SRC/$f" "$DEST/"
  done
fi
cd "$DEST"

# 2. Create config.json once. Never overwrites an existing one.
if [ ! -f config.json ]; then
  cp config.example.json config.json
  echo "Created $DEST/config.json"
fi
chmod 600 config.json

# 3. Fill smtp settings from environment variables, if given.
"$PY" - <<'PYEOF'
import json, os
p = "config.json"; c = json.load(open(p)); s = c.setdefault("smtp", {})
for env, key in [("SMTP_HOST", "host"), ("SMTP_PORT", "port"), ("SMTP_FROM", "from"),
                 ("SMTP_USERNAME", "username"), ("SMTP_PASSWORD", "password")]:
    v = os.environ.get(env)
    if v:
        s[key] = int(v) if key == "port" else v
json.dump(c, open(p, "w"), indent=2)
PYEOF

# 4. Schedule the daily run.
schedule_launchd() {
  # If the Mac is asleep at send time, launchd runs the job on wake.
  local plist="$HOME/Library/LaunchAgents/$LABEL.plist"
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$PY</string><string>$DEST/usage_report.py</string></array>
  <key>WorkingDirectory</key><string>$DEST</string>
  <key>StartCalendarInterval</key><dict>
    <key>Hour</key><integer>$HOUR</integer><key>Minute</key><integer>$MINUTE</integer>
  </dict>
  <key>StandardOutPath</key><string>$DEST/run.log</string>
  <key>StandardErrorPath</key><string>$DEST/run.log</string>
</dict></plist>
PLIST
  launchctl unload "$plist" 2>/dev/null || true
  launchctl load "$plist"
  printf "Scheduled with launchd: every day at %02d:%02d.\n" "$HOUR" "$MINUTE"
}

schedule_cron() {
  command -v crontab >/dev/null || { echo "crontab not found. Install cron, or re-run with SCHEDULER=systemd"; exit 1; }
  local line="$MINUTE $HOUR * * * cd $DEST && $PY usage_report.py >> run.log 2>&1 # claude-usage-emailer"
  { crontab -l 2>/dev/null | grep -v '# claude-usage-emailer' || true; echo "$line"; } | crontab -
  local tz; tz="$(cat /etc/timezone 2>/dev/null || date +%Z)"
  printf "Scheduled with cron: every day at %02d:%02d (%s).\n" "$HOUR" "$MINUTE" "$tz"
  echo "If that timezone is wrong, run: sudo timedatectl set-timezone <Area/City>"
}

schedule_systemd() {
  # A user timer with Persistent=true also catches up on a run missed while the
  # machine was off. On a headless box, run once: sudo loginctl enable-linger $USER
  local dir="$HOME/.config/systemd/user"
  mkdir -p "$dir"
  cat > "$dir/$UNIT.service" <<UNITEOF
[Unit]
Description=Email daily Claude API spend

[Service]
Type=oneshot
WorkingDirectory=$DEST
ExecStart=$PY $DEST/usage_report.py
StandardOutput=append:$DEST/run.log
StandardError=append:$DEST/run.log
UNITEOF
  cat > "$dir/$UNIT.timer" <<UNITEOF
[Unit]
Description=Daily Claude API spend email

[Timer]
OnCalendar=*-*-* $(printf '%02d:%02d' "$HOUR" "$MINUTE"):00
Persistent=true

[Install]
WantedBy=timers.target
UNITEOF
  systemctl --user daemon-reload
  systemctl --user enable --now "$UNIT.timer"
  printf "Scheduled with a systemd user timer: every day at %02d:%02d.\n" "$HOUR" "$MINUTE"
  loginctl show-user "$USER" -p Linger 2>/dev/null | grep -q yes \
    || echo "To keep it running while you're logged out: sudo loginctl enable-linger $USER"
}

if [ "$OS" = "Darwin" ]; then
  schedule_launchd
elif [ "$SCHEDULER" = "systemd" ]; then
  schedule_systemd
else
  schedule_cron
fi

# 5. Say what is left.
echo
if grep -q 'PASTE_ADMIN_KEY_HERE' config.json; then
  echo "Next: paste your Admin API key into $DEST/config.json, then run"
  echo "  python3 $DEST/usage_report.py --check"
else
  "$PY" usage_report.py --check || true
fi
"$PY" -c "import json,sys; s=json.load(open('config.json'))['smtp']; sys.exit(0 if s.get('from') and s.get('password') else 1)" \
  || echo "Email is not set up yet: fill in the smtp section of config.json."
