# Maths to Failure

Adaptive IEB Grade 12 Mathematics practice for the iPad. You upload past papers and memorandums, answer questions by hand, and photograph your working. An AI model marks it against the memorandum, finds the exact line where you went wrong, and keeps pressing on that skill in new forms until you hold it.

No server, no build step. It is plain HTML, CSS and JavaScript. Your API key and data stay in your browser.

## How it works

1. **Library.** Upload a question paper and its memo (PDF). The model extracts each question, its mark allocation, topic and skill.
2. **Session.** Choose a time limit. The app picks your weakest skills and raises the difficulty (levels 1 to 5) until you fail. After a failure it keeps asking about that skill in new phrasings until you pass twice in a row, then moves on.
3. **Marking.** Photograph your working. The model transcribes it line by line, marks against the memo (with consistent accuracy), and names the first mistake and the error pattern, for example `sign_error_expanding`.
4. **Weak spots.** Skills are tracked at three layers: topic, skill, and error pattern. You can start a session aimed at any one skill.

## Reliability measures

- Marking is against the memorandum you uploaded, not the model's own idea of the answer.
- You see the transcription of what the model read, so a misread line is obvious.
- **I disagree** re-marks with your objection. **Set my own mark** overrides it; these are recorded as such.
- Generated questions are checked by solving them again independently and comparing answers. If three attempts fail the check, the question is shown marked "Answer unconfirmed".
- Unreadable photos are not marked.

It can still be wrong. Treat it as a strong practice partner, not an examiner.

## Limits

- Questions that need a figure or graph (much of Euclidean geometry and some function questions) cannot be asked as text. They are used as style examples only.
- Each marking call sends your photos to Claude or Gemini and costs a small amount on your API account.
- Safari clears site data for sites unused for about a week unless the app is added to the Home Screen. Use Settings, Export backup now and then.

## Running it

It needs to be served over HTTPS (or opened locally) so the browser allows the API calls.

- **GitHub Pages:** enable Pages for this repo and open the link in Safari, then Share, Add to Home Screen.
- **Local:** `python3 -m http.server 8000` in this folder, then open `http://localhost:8000`.

Add your key in **Settings**. Model names are editable because providers rename them; if a call fails with "model not found", change the name there.

## Privacy

The key is stored in this browser's local storage and sent only to `api.anthropic.com` or `generativelanguage.googleapis.com`. A Content Security Policy in `index.html` blocks requests to any other site. Do not use the app on a shared device.

## Files

- `index.html`, `styles.css`, `app.js`: the whole app
- `manifest.webmanifest`: Home Screen install
