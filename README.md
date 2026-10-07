# claude-usage-emailer

A daily email of your Claude API spend, split by person or team.

If several people share one Anthropic organisation, usually only the admin can see who spent what. This script asks Anthropic's Admin Usage & Cost API every morning and emails everyone a short table. It makes no model calls, so it costs zero tokens to run, and it needs nothing beyond Python 3.

```
Claude API spend: Tue 06 Oct

Bob            yesterday     $15.00   October    $150.00   ~$750.00/30d
Alice          yesterday      $2.50   October     $25.00   ~$125.00/30d  | 25% of $100.00
Carol          yesterday      $0.42   October      $6.10   ~$30.50/30d
Other          yesterday      $0.40   October      $4.00

Whole account: yesterday $18.32, October $185.10
```

## How it splits spend

- **By workspace (exact).** If each person or team has their own workspace in the Claude Console, they get Anthropic's own cost figure for that workspace. This is the most accurate setup.
- **By API key (estimated).** If people share a workspace but use their own keys, the script takes the workspace's real cost and shares it out by each key's token usage, weighted by model price. The total is always exact, and each person's share is a close estimate.

You can mix both kinds of members in one config. Anything that doesn't belong to a member shows as "Other".

## Requirements

- An Anthropic **organisation** account. The usage API isn't available on individual accounts.
- An **Admin API key** (starts with `sk-ant-admin`). An org admin can create one in the Console under Settings → Admin keys.
- An email account that can send over SMTP, such as a Gmail app password.
- Python 3.8 or later.

## Install on macOS

```bash
git clone https://github.com/OakleyG/claude-usage-emailer.git
cd claude-usage-emailer
bash setup.sh
```

This installs to `~/claude-usage-emailer`, creates `config.json`, and schedules a run for 08:00 every day with launchd. If the Mac is asleep at 08:00, it sends when it wakes up. You can change the time with `SEND_HOUR=7 SEND_MINUTE=30 bash setup.sh`.

## Install on a Raspberry Pi

Raspberry Pi OS already has Python 3. An always-on Pi is a good home for this, because it never misses a morning.

```bash
git clone https://github.com/OakleyG/claude-usage-emailer.git
cd claude-usage-emailer
bash setup.sh
```

This installs to `~/claude-usage-emailer` and adds a cron job for 08:00. Cron uses the Pi's own timezone, so check it with `timedatectl` and set it with `sudo timedatectl set-timezone <Area/City>` if needed.

## Configure

Edit `~/claude-usage-emailer/config.json`:

1. Paste your Admin key into `admin_key`.
2. Fill in `smtp`. For Gmail, use host `smtp.gmail.com`, port `587`, and an app password from myaccount.google.com/apppasswords.
3. Add one entry to `members` for each person or team:
   ```json
   { "name": "Alice", "email": "alice@example.com", "workspace": "Alice's Workspace" }
   { "name": "Carol", "email": "carol@example.com", "api_keys": ["carol-laptop"] }
   ```
   Workspaces and keys can be given by name or by ID. You can list several with `"workspaces": [...]`. `monthly_budget_usd` is optional.
4. Check that it works:
   ```bash
   python3 ~/claude-usage-emailer/usage_report.py --check     # lists workspaces, keys and any mismatches
   python3 ~/claude-usage-emailer/usage_report.py --preview   # prints the email without sending
   ```

### Other options

| Key | Default | What it does |
|---|---|---|
| `send_mode` | `"digest"` | `"digest"` sends everyone the full table. `"individual"` sends each member only their own row. |
| `digest_recipients` | `[]` | Extra addresses that get the full table, such as an admin or finance team. |
| `show_unassigned` | `true` | Shows or hides the "Other" row. |
| `cost_amount_unit` | `"cents"` | If `--preview` totals are exactly 100× too small compared with the Console, set this to `"dollars"`. |
| `prices` | built in | Overrides the price table used for per-key estimates. |

`ANTHROPIC_ADMIN_KEY` and `SMTP_PASSWORD` environment variables override the config file. `USAGE_EMAILER_CONFIG` points to a config file somewhere else.

## Let an agent set it up

If you have an AI agent on the machine, point it at [AGENT_SETUP.md](AGENT_SETUP.md). It installs and schedules everything and reuses the email account the agent already sends from. You only paste in the Admin key.

## Notes

- Days are in UTC, the same as Anthropic billing. Usage data can lag a few hours, so yesterday's figure is the reliable one.
- `config.json` holds secrets. The installer sets it to owner-only permissions, and `.gitignore` keeps it out of git.
- Logs are in `run.log` in the install folder.

## Uninstall

macOS:

```bash
launchctl unload ~/Library/LaunchAgents/com.github.claude-usage-emailer.plist
rm ~/Library/LaunchAgents/com.github.claude-usage-emailer.plist
rm -rf ~/claude-usage-emailer
```

Raspberry Pi:

```bash
crontab -l | grep -v '# claude-usage-emailer' | crontab -
rm -rf ~/claude-usage-emailer
```

## License

MIT
