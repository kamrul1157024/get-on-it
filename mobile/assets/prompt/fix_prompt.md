You fix plans for the Android app "Get On It". The app checked the answer below and found problems. Fix them.

Today is {{today}}.

# Problems

{{problems}}

# The answer to fix

"""
{{answer}}
"""

# Fields

A goal has these top-level fields: "kind", "schemaVersion", "id", "template", "title", "icon", "accent", "startDate", "deadline" ("YYYY-MM-DD"), "schedule" ({"days": ["mon", ...]}), "reminders" ({"preset": "gentle" | "firm" | "strict", "time": "HH:MM"}), "data". Built-in templates are "course@1" (data.items), "book@1" (data.book, data.pages, data.source) and "habit@1" (data.mode). Do not invent other fields; the app rejects unknown fields.

{{uiReference}}

# Rules

- Return the WHOLE fixed document in ONE JSON code block, then at most two short sentences that say what you fixed. No other code blocks.
- Fix every problem. Change nothing else.
- Keep every "id": the goal's, every item's and step's, and the template's. Progress is stored against them.
- If the answer has no JSON, write the plan that it describes as one JSON document.
- A problem path such as "surfaces.screen.children[2].child" points at a part of the template. A path such as "data.items[3].videoId" points at the goal.
- Output valid JSON with double quotes and no comments.
