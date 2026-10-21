# Install the getonit-planner skill

The `getonit-planner` skill makes plan files for the Get On It app.
You ask for a goal. Claude makes a `.getonit.json` file. You open the file on your phone.

The skill is in this repository:

- `skill/` is a Claude Code plugin.
- `skill/skills/getonit-planner/` is the skill folder. It has `SKILL.md` in it.
- `.claude-plugin/marketplace.json` makes this repository a plugin marketplace named `get-on-it`.


## No install: copy a prompt

You do not need to install anything to make a plan:

1. In the app, tap **Make a plan with AI**.
2. Say what you want.
3. Tap **Copy prompt**. Paste it into Claude, ChatGPT, or another chat.
4. Copy the whole answer. In the app, tap **Import a plan**, then **Paste**.

To change a plan, open the goal and tap **⋮ → Change plan with AI**. The prompt contains the plan and your progress, and it tells the AI to keep the IDs, so your progress stays.

The skill below does more. It looks up real YouTube video IDs and durations, and it checks the plan before it gives it to you.

## Claude Code: install the plugin

Run these commands in Claude Code:

```
/plugin marketplace add kamrul1157024/get-on-it
/plugin install getonit-planner@get-on-it
```

You can also run them in a shell:

```bash
claude plugin marketplace add kamrul1157024/get-on-it
claude plugin install getonit-planner@get-on-it
```

The repository is private. Claude Code uses the git credentials on your machine.
Set up an SSH key for GitHub, or run `gh auth login` first.

To try the plugin without installing it, start Claude Code from the repository root:

```bash
claude --plugin-dir ./skill
```

## Claude Code: install only the skill

Copy the skill folder to one of these places:

- For you, in all projects: `~/.claude/skills/getonit-planner/`
- For one project: `.claude/skills/getonit-planner/` in that project

```bash
mkdir -p ~/.claude/skills
cp -r skill/skills/getonit-planner ~/.claude/skills/
```

Claude uses the skill when your request matches its description.
You can also type `/getonit-planner` to start it.

## claude.ai and Claude desktop

1. Build the zip file. Run `skill/build-zip.sh`. The script writes `skill/dist/getonit-planner.zip`.
2. Open Settings > Features > Skills.
3. Select "Upload custom skill".
4. Upload `getonit-planner.zip`.

Code execution must be on.
The zip root must be the `getonit-planner/` folder. The build script does this for you.

Your settings, or your admin's settings, control network access in the code sandbox.
The playlist script needs to reach YouTube. If it cannot, Claude still makes the plan.
Claude then tells you that the video IDs need a check. You can run the script on your computer and give Claude the output.

## Claude API

Upload the skill with the Python SDK:

```python
import anthropic
from anthropic.lib import files_from_dir

client = anthropic.Anthropic()

skill = client.skills.create(
    display_title="Get On It planner",
    files=files_from_dir("skill/skills/getonit-planner"),
)
```

Then call Messages with the skill in the container and the code execution tool:

```python
response = client.messages.create(
    model="claude-opus-5-5",
    max_tokens=16000,
    container={"skills": [{"type": "custom", "skill_id": skill.id, "version": "latest"}]},
    tools=[{"type": "code_execution_20250825", "name": "code_execution"}],
    messages=[{"role": "user", "content": "Make a Get On It plan to drink 8 glasses of water a day."}],
)
```

The API sandbox has no network access.
For a course, run `playlist_to_items.py` on your computer first. Then put its output in the prompt.

## OpenAI Codex CLI

Copy the skill folder to one of these places:

- For you: `~/.agents/skills/getonit-planner/`
- For one repository: `.agents/skills/getonit-planner/` in that repository

```bash
mkdir -p ~/.agents/skills
cp -r skill/skills/getonit-planner ~/.agents/skills/
```

To use the skill, type `$getonit-planner` or use `/skills`.
Codex can also pick the skill from its description.

To run Codex without the interactive screen, use `codex exec --sandbox workspace-write "..."`.
The `--full-auto` flag is no longer supported.
The default sandbox is read-only, so the skill cannot write the plan file there.

The playlist script needs network access. If the sandbox blocks it, run the script yourself and paste the output.

## Other tools

Some tools support the open Agent Skills standard (folders with a `SKILL.md` file).
Copy the `skill/skills/getonit-planner` folder into that tool's skills folder.

## Sample commands

Claude Code, interactive:

```
claude
/getonit-planner Make a plan to finish Stanford CS229 by 31 December, 3 study days a week
```

Claude Code, non-interactive:

```bash
claude -p "Use the getonit-planner skill. Make a Get On It plan to finish Stanford CS229 (https://www.youtube.com/playlist?list=PLoROMvodv4rMiGQp3WXShtMGgzqpfVfbU) by 2026-12-31, studying Mon/Wed/Fri. Save it as cs229.getonit.json." --allowedTools "Bash(python3 *)" "Write"
```

Codex:

```bash
codex exec --sandbox workspace-write '$getonit-planner Make a Get On It plan to read Atomic Habits (320 pages) by 2026-12-15, every day. Save it as atomic-habits.getonit.json.'
```

## Send the plan to your phone

Use one of these ways:

- **Share.** Send the file or the JSON text to your phone. Tap Share and select Get On It.
- **Open with.** Open the `.getonit.json` file on your phone, for example from Downloads, Google Drive, or a chat app. Select "Open with" > Get On It.
- **Paste.** Copy the JSON text. Open Get On It. Tap "Import a plan" (or the "Import plan" button), then "Paste".

The app shows a preview before it saves the plan.
Check the plan there. Turn on the reminders that you want.
