#!/usr/bin/env bash
# Installer for claude-usage-emailer on macOS. Safe to run more than once.
#
# Optional environment variables:
#   INSTALL_DIR    where to install           (default ~/claude-usage-emailer)
#   SEND_HOUR      hour to send, 0-23         (default 8)
#   SEND_MINUTE    minute to send, 0-59       (default 0)
#   SMTP_HOST SMTP_PORT SMTP_FROM SMTP_USERNAME SMTP_PASSWORD
#                  fill the smtp section of config.json without editing it by hand
set -euo pipefail

if [ "$(uname)" != "Darwin" ]; then
  echo "This version of setup.sh supports macOS only."
  exit 1
fi

SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="${INSTALL_DIR:-$HOME/claude-usage-emailer}"
HOUR="${SEND_HOUR:-8}"
MINUTE="${SEND_MINUTE:-0}"
LABEL="com.github.claude-usage-emailer"
PY="$(command -v python3 || true)"
[ -z "$PY" ] && { echo "python3 not found. Run: xcode-select --install"; exit 1; }

# 1. Copy files. Keep this outside Documents/Desktop/Downloads: macOS stops
#    background jobs reading those folders.
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
"$PY" - <<'EOF'
import json, os
p = "config.json"; c = json.load(open(p)); s = c.setdefault("smtp", {})
for env, key in [("SMTP_HOST", "host"), ("SMTP_PORT", "port"), ("SMTP_FROM", "from"),
                 ("SMTP_USERNAME", "username"), ("SMTP_PASSWORD", "password")]:
    v = os.environ.get(env)
    if v:
        s[key] = int(v) if key == "port" else v
json.dump(c, open(p, "w"), indent=2)
EOF

# 4. Schedule with launchd. If the Mac is asleep at send time it runs on wake.
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
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
EOF
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"
printf "Scheduled with launchd: every day at %02d:%02d.\n" "$HOUR" "$MINUTE"

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
