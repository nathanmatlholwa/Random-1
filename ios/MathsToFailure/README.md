# Maths to Failure for iPad and Mac

A SwiftUI app (iPad, and Mac through Mac Catalyst) that practises IEB Grade 12 Mathematics by pressing on the exact skills you get wrong. It is the native version of the web app in the repo root, with three additions:

- **Many papers at once.** Pick a stack of question papers and memorandums in one go. They are matched by file name, the originals are kept in your private Supabase Storage, and every question and memo line is read out in small chunks.
- **A Supabase database.** Papers, questions, skill levels, error patterns and every attempt are saved to your own account and appear on every device you sign in on.
- **Different models for different jobs.** Reading papers, marking, writing questions and checking answers each have their own Claude or Gemini model.

It also adds **Apple Pencil writing inside the app**, a **Challenge mode** that writes new hard questions, and an **answer check done by a different model family** than the one that wrote the question.

## Run it

You need a Mac with Xcode 16 or later. There is no Swift compiler in the environment this code was written in, so it has not been compiled yet. Expect a few small compile errors on the first build. Paste them to Claude and they are quick to fix.

### Option A: XcodeGen (recommended)

```sh
brew install xcodegen
cd ios/MathsToFailure
xcodegen generate
open MathsToFailure.xcodeproj
```

In Xcode, select the **MathsToFailure** target, open **Signing & Capabilities** and choose your Team (a free Apple ID works). Pick an iPad or **My Mac (Mac Catalyst)** and press Run.

### Option B: by hand

1. Xcode, File, New, Project, iOS App. Product name `MathsToFailure`, interface SwiftUI, language Swift.
2. Delete the generated `ContentView.swift` and app file. Drag the `Sources` folder into the project (create groups, add to target).
3. Target settings: Minimum deployment iOS 17. Supported Destinations: iPad, and add Mac (Mac Catalyst). Swift Language Version 5.
4. Signing & Capabilities: add **App Sandbox** with *Outgoing Connections (Client)* and *User Selected File (Read Only)*, and **Keychain Sharing**. Or use the supplied `MathsToFailure.entitlements`.
5. Info: add `NSCameraUsageDescription` ("Take a photo of your handwritten working so it can be marked.").
6. Optional tests: add a Unit Testing Bundle target and put `Tests/CoreTests.swift` in it.

## First launch

1. **Create an account** with an email and password. Supabase may email you a confirmation link first. For a personal project you can switch that off in the Supabase dashboard under Authentication, Providers, Email, "Confirm email".
2. **Settings, API keys.** Paste your Anthropic key and/or Gemini key. They go straight into the device Keychain.
3. **Settings, Models.** Pick a model for each job, or leave the defaults. Model names change, so you can type any id the provider lists.
4. **Library, Choose PDFs.** Select papers and memos together, check the pairs, then Upload and read.
5. **Session.** Choose a time limit and a mode, then start.

## Where things live

| Thing | Where | Notes |
|---|---|---|
| AI provider keys | Device Keychain | Never sent to Supabase. They do not sync, so enter them on each device. |
| Supabase session | Device Keychain | Refreshed automatically. |
| Papers, questions, skills, attempts | Supabase (project `maths-to-failure`, eu-west-2) | Row Level Security: each account sees only its own rows. |
| Original PDFs | Supabase Storage bucket `papers` (private) | Stored under `<your user id>/`. Used for "Read again". |
| Model choices, time limit | UserDefaults | Not secret. |

`Sources/Core/Config.swift` holds the project URL and the **publishable** key. That key is meant to ship inside apps. Never put a `service_role` key or an AI key in the source.

The database schema and security policies are in `../../supabase/migrations/20261007000000_init.sql`.

## Layout

```
Sources/
  App/     entry point
  Core/    Supabase client, Claude and Gemini clients, prompts, adaptive engine, session logic
  Views/   SwiftUI screens, Apple Pencil canvas, math rendering
Tests/     engine, JSON repair and file pairing tests
```

No third-party packages are used. Supabase and both model APIs are called over plain HTTPS.

## Known limits

- Equations render with KaTeX loaded from a CDN, so they need an internet connection. Without one the raw LaTeX text shows.
- Questions that need a figure or graph cannot be asked as text. They are used only as style examples.
- Nothing is queued offline. A failed save shows a message and the data is not retried.
- Marking is done by an AI reading handwriting and can be wrong. Use "I disagree with the marking" or "Set my own mark".
- Reading a paper makes several model calls and costs money on your API account. Papers are read two questions at a time and the memo is cached on Claude to reduce the cost.
