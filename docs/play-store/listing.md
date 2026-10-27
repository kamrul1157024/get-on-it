# Google Play listing: Get On It

Copy these texts into Play Console. The limits are Google's.

## App details

| Field | Text |
|---|---|
| App name (30 characters at most) | Get On It |
| Short description (80 characters at most) | Plans from your AI chat, nudges that push you, widgets that keep goals in sight. |
| Category | Productivity |
| Tags | Productivity, Habit tracker, Education |
| Email | Your support email (Play Console shows it on the listing) |
| Website | https://github.com/kamrul1157024/get-on-it |
| Privacy policy | https://kamrul1157024.github.io/get-on-it/privacy |

## Full description (4000 characters at most)

```
Get On It helps you finish what you start. Do the thing.

Create a plan in 3 steps
1. Say what you want: finish a YouTube course, read a book, exercise 4 days a week, drink more water. Ask for several things at once if you like.
2. Tap "Open ChatGPT" or "Open Claude". Get On It copies a prompt for you. Paste it and send it. Any AI chat works.
3. Copy the answer and come back. Get On It finds the plan and adds it. One tap undoes it.
A short video in the app shows you how.

Get On It contains no AI. You use your own AI chat.

Courses, books and habits
- Watch course videos from where you stopped.
- Read today's pages of a book or a PDF.
- Plan a different exercise for each day. You see only today's.
- Count glasses of water, tick a checklist, or keep a "do not" habit.
- See your streak, your pace against your deadline, and today's task first.
- Want a different look? Ask your AI: "make it pink with a big streak counter".

Time lost
With your permission, Get On It shows how much time social, video and game apps took today, this month and this year, and what that time could have been: "That could have been 13 lectures." This data stays on your phone.

Nudges that push you
Choose how hard Get On It pushes you:
- Gentle: 2 soft nudges a day.
- Firm: 4 nudges a day, with the time you lost.
- Push me hard: up to 12 nudges a day, and a stop screen over an app that passed its limit. "Back to the app" works after 10 seconds.
Nudges stop in quiet hours and when today's work is done. Every nudge has "Break 1 h".

Reminders that work
Notifications, reminders that stay until you act, and alarms. You approve every reminder. Quiet hours and a daily limit keep it fair.

Home-screen widgets
A "Today" widget and a goal widget show your progress. Buttons such as +1 and Done work without opening the app.

Your data stays yours
- No account, no ads, no analytics.
- Your goals and progress stay on your phone.
- Android can back them up to your own Google account.

Get On It is not affiliated with or endorsed by OpenAI or Anthropic.
```

## Graphics

| Asset | File |
|---|---|
| App icon, 512 × 512 | `icon-512.png` |
| Feature graphic, 1024 × 500 | `feature-graphic.png` |
| Phone screenshots, 1080 × 1920, 24-bit PNG | `screenshots/01-today.png` … `07-nudge-strength.png`, in this order |

The screenshots come from the Play build on an Android 16 emulator. They show no video thumbnails, so no third-party images appear on the store.

## Permission declarations

### Foreground service: special use

Play Console → App content → Foreground service permissions → "Special use".

Description:

```
Get On It runs a foreground service only while the user has turned on "Distraction nudges". The service listens for the user unlocking the phone and checks, every 2 minutes while the screen is on, how long the user has spent today in apps that the user chose to limit. When a limit is passed, it shows a reminder of the user's own goal. The service shows a persistent notification while it runs. The user turns it off in the app's Settings. No other Android foreground service type fits this use.
```

Demo video (upload to YouTube as unlisted, about 30 seconds):

1. Open Settings, turn on "Distraction nudges". The persistent notification appears.
2. Choose an app to limit (for example Chrome) with a short limit.
3. Use that app past the limit. The nudge with the goal appears.
4. Turn nudges off. The notification disappears.

### Full-screen intent

Play Console → App content → Full-screen intent. Core use: **Alarms**.

```
Get On It is a goal app with alarms. The user sets a strict alarm for a goal, for example "study at 7:00 PM". The alarm shows full screen at that time, also on the lock screen, and rings until the user starts the work or snoozes it. Without full-screen intent, the alarm shows only as a notification.
```

If Google rejects this declaration, the app still works: alarms show as ringing notifications.

### Usage access and "Display over other apps"

No form in Play Console. The app shows a prominent disclosure before it asks for either one ("Get On It reads your app usage", "Get On It shows a stop screen"), with "Agree and continue" and "Not now".

## Data safety

| Question | Answer |
|---|---|
| Does the app collect or share user data? | No. All data stays on the device. Android's own backup is a system feature, not collection by the app. |
| Is data encrypted in transit? | Yes. The app's network calls (YouTube, GitHub pages, websites in plans) use HTTPS. |
| Can users ask for their data to be deleted? | Yes. Delete a goal in the app, or uninstall the app. There is no server copy. |
| Data types collected | None |
| Data types shared | None |

Note for the form: usage access ("App activity → Other user-installed apps / App interactions") is processed only on the device and never leaves it, so it is not "collected" in Google's sense.

## Ads

The app contains no ads.

## Content rating (IARC questionnaire)

| Topic | Answer |
|---|---|
| Category | Utility, productivity, communication or other |
| Violence, sexual content, profanity, drugs, gambling | No |
| User-generated content shared with other users | No |
| Users can talk to each other | No |
| Shares the user's location | No |
| Lets users buy digital goods | No |
| Unrestricted internet access (a web browser) | No. It opens links from the user's own plans in other apps. |

Expected rating: Everyone / PEGI 3.

## Target audience

13 and older. The app is not made for children and does not appeal to them.

## AI policy

- Get On It contains no AI model and generates no content. Google Play's AI-generated content policy is for apps that generate content with AI, so it does not apply.
- The user writes a request, copies the app's prompt into an AI chat of their choice, and pastes the answer back. The app checks the answer as data (a plan) and shows it only to that user.
- ChatGPT and Claude appear only as examples, in plain text. The app and the listing use no logos of other companies and do not suggest that OpenAI or Anthropic endorse the app.
