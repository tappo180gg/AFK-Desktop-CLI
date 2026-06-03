# afk.sh v1.4.1 💤 (Beta)

**Away From Keyboard manager for Linux.**

A bash script that tracks your PC absences with timers, desktop notifications, statistics, auto-AFK, and more — all from the terminal.

![Terminal](https://img.shields.io/badge/terminal-bash-4EAA25?logo=gnu-bash&logoColor=white)
![License](https://img.shields.io/badge/license-MIT-blue)

---

## Features

- 🎯 **Quick start** — `afk lunch` and you're done
- ⏱️ **Countdown timer** — with notification on expiry
- 📊 **Statistics** — ASCII chart by reason, today/week/total stats
- 📤 **CSV Export** — open your data in Excel or Google Sheets
- 🔙 **Return from another terminal** — `afk --back`
- 🔄 **Self-update** — `afk --update` downloads the latest version from GitHub
- 💤 **Auto-AFK** — detects PC idle and logs automatically
- 🎨 **Customizable colors** — configure border, title, text, and timer colors
- 🔒 **Auto lock screen** — lock your PC when you go AFK
- 💬 **Slack integration** — set your Slack status automatically (via xdotool)
- 📝 **Notes** — attach a message to any session
- ✏️ **Edit** — change the reason of the last session
- ❌ **Cancel** — abort an AFK session without logging it
- 🧹 **Clean** — remove logs older than N days

---

## Installation

```bash
git clone https://github.com/tappo180gg/AFK-Desktop-CLI.git
cd AFK-Desktop-CLI
./install.sh
source ~/.bashrc   # or ~/.zshrc
```

or manual:

```bash
mkdir -p ~/.local/bin
cp afk.sh ~/.local/bin/afk
chmod +x ~/.local/bin/afk
```

## Usage
```bash
afk                       # AFK with default reason
afk lunch                 # Quick alias → "Lunch, 60 min"
afk coffee                # Quick alias → "Coffee, 5 min"
afk "meeting" 30          # Custom reason, 30 min
afk 15                    # 15 min with default reason
afk --msg "brb"           # With a custom note
```
## Commands:

| Command | Description |
|---------|-------------|
| `afk --status` | Current AFK status + PC idle time |
| `afk --back` | Report return from another terminal |
| `afk --cancel` | Cancel without logging |
| `afk --stats` | Statistics and history |
| `afk --export [file.csv]` | Export log to CSV |
| `afk --edit` | Edit last session reason |
| `afk --clean [days]` | Clean old logs (default: 90) |
| `afk --aliases` | Show quick aliases |
| `afk --config` | Interactive configuration |
| `afk --update` | Update to the latest version |
| `afk --version` | Show version |

## Quick Aliases
Preconfigured and customizable:

| Alias | Reason | Duration |
|-------|--------|----------|
| `lunch` | Lunch | 60 min |
| `coffee` | Coffee | 5 min |
| `meeting` | Meeting | — |
| `bathroom` | Bathroom | 5 min |
| `phone` | Phone | — |
| `break` | Break | 15 min |

Add your own in ~/.config/afk/config:
```QUICK_REASONS="lunch:Lunch:60;coffee:Coffee:5;stream:Stream:120"```

## Auto-AFK (Idle Detection)

Install **xprintidle** and set the threshold:
```bash
sudo apt install xprintidle
afk --config   # set "Auto-AFK after X min idle"
```

Then add this to your crontab for automatic checks every 5 minutes:

```bash
crontab -e
# Add this line:
*/5 * * * * /home/$USER/.local/bin/afk --daemon
```

## Configuration
Everything is stored in ~/.config/afk/:

| File | Content |
|------|---------|
| `config` | Custom settings (colors, aliases, etc.) |
| `history.log` | Session logs |

Run afk --config for the guided setup wizard.

## Optional Dependencies

| Package | Function |
|-----------|----------|
| `notify-send` | Desktop notifications (usually preinstalled) |
| `xdotool` | Automatic Slack status |
| `xprintidle` | Idle detection for auto-AFK |
| `curl` or `wget` | For `--update` |

