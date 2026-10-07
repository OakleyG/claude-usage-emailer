# Setup instructions for an AI agent

You are installing claude-usage-emailer on this machine. It is one Python script that uses only the standard library. Once it's installed it makes no model calls. Do not route the daily report through yourself, because the point of this tool is that it costs zero tokens.

## Steps

1. **Find SMTP credentials this machine already uses** to send email. Look in your own email-sending setup, its environment variables or config, or a `.env` file. You need the host, port, from-address, username and password.
2. **Run the installer** from the repo folder, passing those credentials as environment variables:
   ```bash
   SMTP_HOST=smtp.example.com SMTP_PORT=587 SMTP_FROM=reports@example.com \
   SMTP_USERNAME=reports@example.com SMTP_PASSWORD='...' bash setup.sh
   ```
   It is safe to run more than once. It installs to `~/claude-usage-emailer`, creates `config.json` and schedules a daily run (launchd on macOS, cron on Linux).
3. If you can't find any SMTP credentials, run `bash setup.sh` without them. Tell the owner that the `smtp` section of `config.json` still needs filling in.
4. **Fill in `members` only if the owner told you who they are.** Otherwise leave the example entries and tell the owner to edit them. Running `usage_report.py --check` lists the real workspaces and keys once the admin key is in.
5. **Do not create, request or handle the Anthropic Admin API key.** Tell the owner to:
   - create one in the Claude Console under Settings → Admin keys
   - paste it into `~/claude-usage-emailer/config.json`, replacing `PASTE_ADMIN_KEY_HERE`
   - run `python3 ~/claude-usage-emailer/usage_report.py --check`, then `--preview`
6. **Report back** with the install path, the scheduled time, and what the owner still needs to do.

## Rules

- Never print, log or commit the contents of `config.json`.
- If `--preview` totals are exactly 100× smaller than the Console shows, set `"cost_amount_unit": "dollars"`.
