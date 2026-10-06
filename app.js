'use strict';
/* Maths to Failure: adaptive IEB Grade 12 maths practice.
   Everything runs in the browser. Your API key and data stay in this browser's storage. */

/* ---------- helpers ---------- */
const $ = (s, el = document) => el.querySelector(s);
const $$ = (s, el = document) => Array.from(el.querySelectorAll(s));
const esc = (v) => String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const uid = () => Math.random().toString(36).slice(2, 10);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const clamp = (n, lo, hi) => Math.min(hi, Math.max(lo, n));
const pct = (n) => Math.round(n * 100);

let toastTimer;
function toast(msg) {
  const t = $('#toast');
  t.textContent = msg;
  t.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => (t.hidden = true), 4200);
}

function typeset(el) {
  if (window.renderMathInElement && el) {
    try {
      window.renderMathInElement(el, {
        delimiters: [
          { left: '$$', right: '$$', display: true },
          { left: '\\[', right: '\\]', display: true },
          { left: '\\(', right: '\\)', display: false },
          { left: '$', right: '$', display: false },
        ],
        throwOnError: false,
      });
    } catch (e) { /* leave the raw text visible */ }
  }
}

/* ---------- constants ---------- */
const TOPICS = [
  'Algebra, equations and inequalities',
  'Sequences and series',
  'Functions, graphs and inverses',
  'Finance, growth and decay',
  'Differential calculus',
  'Counting and probability',
  'Statistics and regression',
  'Analytical geometry',
  'Trigonometry',
  'Euclidean geometry',
];
const LEVELS = {
  1: 'routine, one idea, 2 to 3 marks',
  2: 'standard, two linked steps, 3 to 5 marks',
  3: 'typical exam question, several steps, 5 to 7 marks',
  4: 'hard, needs insight or combines ideas, 6 to 9 marks',
  5: 'unfamiliar problem solving of the kind found at the end of an IEB paper, 8 to 12 marks',
};
const DEFAULT_MODELS = { claude: 'claude-sonnet-5-5', gemini: 'gemini-2.5-flash' };
const STORE_KEY = 'mtf.v1';

/* ---------- storage ---------- */
function defaults() {
  return {
    settings: { provider: 'claude', claudeKey: '', geminiKey: '', claudeModel: DEFAULT_MODELS.claude, geminiModel: DEFAULT_MODELS.gemini, verify: true, minutes: 30 },
    bank: [],      // questions extracted from your papers
    papers: [],    // {id, name, addedAt, count}
    skills: {},    // "topic||skill" -> state
    attempts: [],  // marked attempts
    seen: [],      // bank ids already served
  };
}
let S = load();
function load() {
  const d = defaults();
  try {
    const raw = localStorage.getItem(STORE_KEY);
    if (raw) {
      const p = JSON.parse(raw);
      return Object.assign(d, p, { settings: Object.assign(d.settings, p.settings || {}) });
    }
  } catch (e) { /* start fresh */ }
  return d;
}
function save() {
  try { localStorage.setItem(STORE_KEY, JSON.stringify(S)); }
  catch (e) { toast('Could not save. Browser storage may be full or blocked.'); }
}

/* ---------- model calls ---------- */
class ApiError extends Error {}

function activeKey() { return S.settings.provider === 'claude' ? S.settings.claudeKey : S.settings.geminiKey; }

async function callModel({ system, parts, maxTokens = 4096 }) {
  if (!activeKey()) throw new ApiError('Add your API key in Settings first.');
  let lastErr;
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      return S.settings.provider === 'claude' ? await callClaude(system, parts, maxTokens) : await callGemini(system, parts, maxTokens);
    } catch (e) {
      lastErr = e;
      if (!(e instanceof ApiError) || !e.retry) throw e;
      await sleep(2500);
    }
  }
  throw lastErr;
}

async function post(url, headers, body) {
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), 240000);
  let res;
  try {
    res = await fetch(url, { method: 'POST', headers, body: JSON.stringify(body), signal: ctl.signal });
  } catch (e) {
    throw new ApiError(e.name === 'AbortError' ? 'The model took too long to answer.' : 'Network error. Check your connection.');
  } finally { clearTimeout(timer); }
  let data = null;
  try { data = await res.json(); } catch (e) { /* not json */ }
  if (!res.ok) {
    const msg = (data && (data.error?.message || data.error)) || res.statusText;
    const err = new ApiError(`API error ${res.status}: ${typeof msg === 'string' ? msg : JSON.stringify(msg)}`);
    err.retry = res.status === 429 || res.status >= 500;
    throw err;
  }
  return data;
}

async function callClaude(system, parts, maxTokens) {
  const content = parts.map((p) => {
    if (p.type === 'text') return { type: 'text', text: p.text };
    if (p.type === 'pdf') return { type: 'document', source: { type: 'base64', media_type: 'application/pdf', data: p.data } };
    return { type: 'image', source: { type: 'base64', media_type: p.mime, data: p.data } };
  });
  const data = await post('https://api.anthropic.com/v1/messages', {
    'content-type': 'application/json',
    'x-api-key': S.settings.claudeKey,
    'anthropic-version': '2023-06-01',
    'anthropic-dangerous-direct-browser-access': 'true',
  }, { model: S.settings.claudeModel, max_tokens: maxTokens, system, messages: [{ role: 'user', content }] });
  if (data.stop_reason === 'max_tokens') throw new ApiError('The reply was cut off. Try fewer questions at once.');
  return (data.content || []).filter((c) => c.type === 'text').map((c) => c.text).join('');
}

async function callGemini(system, parts, maxTokens) {
  const gp = parts.map((p) => {
    if (p.type === 'text') return { text: p.text };
    return { inline_data: { mime_type: p.type === 'pdf' ? 'application/pdf' : p.mime, data: p.data } };
  });
  const url = `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(S.settings.geminiModel)}:generateContent`;
  const data = await post(`${url}?key=${encodeURIComponent(S.settings.geminiKey)}`, { 'content-type': 'application/json' }, {
    systemInstruction: { parts: [{ text: system }] },
    contents: [{ role: 'user', parts: gp }],
    generationConfig: { responseMimeType: 'application/json', maxOutputTokens: Math.max(maxTokens, 16000) },
  });
  const cand = data.candidates && data.candidates[0];
  if (!cand) throw new ApiError('Gemini returned no answer' + (data.promptFeedback ? ` (${data.promptFeedback.blockReason || 'blocked'})` : '.'));
  if (cand.finishReason === 'MAX_TOKENS') throw new ApiError('The reply was cut off. Try fewer questions at once.');
  return (cand.content?.parts || []).map((p) => p.text || '').join('');
}

/* Models write LaTeX inside JSON. A single backslash before f, t, b, r or n silently turns into a control
   character (\frac becomes form feed + "rac"), so repair those after parsing. */
function repairLatex(v) {
  if (typeof v === 'string') {
    return v
      .replace(/\f(?=rac|orall)/g, '\\f')
      .replace(/\t(?=heta|imes|ext|an(?![a-z])|o(?![a-z])|ilde|au(?![a-z]))/g, '\\t')
      .replace(/\x08(?=eta|ar(?![a-z])|inom|egin|ig)/g, '\\b')
      .replace(/\r(?=ight|ho(?![a-z])|angle)/g, '\\r')
      .replace(/\n(?=eq(?![a-z])|u(?![a-z])|abla|ot(?![a-z])|eg(?![a-z]))/g, '\\n');
  }
  if (Array.isArray(v)) return v.map(repairLatex);
  if (v && typeof v === 'object') { for (const k of Object.keys(v)) v[k] = repairLatex(v[k]); }
  return v;
}
function parseModelJson(text) {
  let t = String(text).trim().replace(/^```(?:json)?\s*/i, '').replace(/```\s*$/, '');
  const a = t.indexOf('{'), b = t.lastIndexOf('}');
  if (a < 0 || b < 0) throw new ApiError('The model did not return usable JSON. Try again.');
  t = t.slice(a, b + 1);
  let obj;
  try { obj = JSON.parse(t); }
  catch (e) {
    try { obj = JSON.parse(t.replace(/\\(?!["\\/bfnrt]|u[0-9a-fA-F]{4})/g, '\\\\')); }
    catch (e2) { throw new ApiError('The model returned malformed JSON. Try again.'); }
  }
  return repairLatex(obj);
}
async function askJson(opts) { return parseModelJson(await callModel(opts)); }

/* ---------- files ---------- */
function fileToBase64(file) {
  return new Promise((res, rej) => {
    const r = new FileReader();
    r.onload = () => res(String(r.result).split(',')[1]);
    r.onerror = () => rej(new Error('Could not read the file.'));
    r.readAsDataURL(file);
  });
}
function imageToJpeg(file, maxSide = 1800) {
  return new Promise((res, rej) => {
    const url = URL.createObjectURL(file);
    const img = new Image();
    img.onload = () => {
      const k = Math.min(1, maxSide / Math.max(img.width, img.height));
      const c = document.createElement('canvas');
      c.width = Math.round(img.width * k);
      c.height = Math.round(img.height * k);
      const ctx = c.getContext('2d');
      ctx.fillStyle = '#fff';
      ctx.fillRect(0, 0, c.width, c.height);
      ctx.drawImage(img, 0, 0, c.width, c.height);
      URL.revokeObjectURL(url);
      const dataUrl = c.toDataURL('image/jpeg', 0.85);
      res({ mime: 'image/jpeg', data: dataUrl.split(',')[1], url: dataUrl });
    };
    img.onerror = () => { URL.revokeObjectURL(url); rej(new Error('That image could not be read. Try a JPEG or PNG screenshot.')); };
    img.src = url;
  });
}

/* ---------- prompts ---------- */
const BASE = `You are a senior IEB Grade 12 Mathematics examiner and teacher in South Africa.
Rules for all replies:
- Reply with one JSON object and nothing else. No code fences, no commentary.
- Write all mathematics in LaTeX inside $...$ (inline) or $$...$$ (display). Never use the dollar sign for money; write Rand amounts as R1 500.
- Inside JSON strings every LaTeX backslash must be written as two backslashes, for example \\\\frac{1}{2}.
- Use South African and IEB conventions, notation and mark allocation (method, accuracy and consistent accuracy marks).`;

function skillKeyOf(q) { return `${q.topic}||${q.skill}`; }
function ensureSkill(topic, skill) {
  const k = `${topic}||${skill}`;
  if (!S.skills[k]) S.skills[k] = { topic, skill, level: 1, mastery: 0.5, attempts: 0, streak: 0, failStreak: 0, failedAt: null, errors: {}, last: 0 };
  return S.skills[k];
}

async function ingestPaper({ label, paper, memo, range, log }) {
  const known = Object.values(S.skills).map((s) => `${s.topic} :: ${s.skill}`).slice(0, 80).join('\n') || '(none yet)';
  const text = `Document 1 is an IEB Grade 12 Mathematics question paper. Document 2 is its memorandum.
${range ? `Extract only these question numbers: ${range}.` : 'Extract every question.'}

Split the paper into the smallest separately answerable parts (for example 4.1, 4.2, 4.3). Copy any shared stem or given information into each part so every part can be answered on its own.
For each part return:
- qnum: the number as printed, e.g. "4.2"
- topic: one of exactly these: ${TOPICS.join(' | ')}
- skill: a short specific skill name (for example "Solve trig equations with a negative angle" or "Differentiate from first principles"). Reuse a name from the list below when it fits; only invent a new one when none does.
- level: 1 to 5 where 1 is routine and 5 is the hardest problem solving
- marks: total marks for the part
- question: the full question text, self-contained, LaTeX for maths
- has_diagram: true if the question cannot be answered without seeing a figure or graph, otherwise false. If true, still describe the figure in words inside question.
- memo: array of {"step": what the memorandum says for this line, "marks": marks for that line}. The marks must add up to marks.
- final_answer: the final answer(s) as a short string

Also return style_notes: two sentences on how this paper phrases and structures its questions.

Existing skill names:
${known}

Return {"questions":[...],"style_notes":"..."}.`;
  log('Reading the paper and memorandum. This can take a minute or two.');
  const out = await askJson({
    system: BASE,
    maxTokens: 16000,
    parts: [{ type: 'pdf', data: paper }, { type: 'pdf', data: memo }, { type: 'text', text }],
  });
  const list = Array.isArray(out.questions) ? out.questions : [];
  let added = 0;
  for (const q of list) {
    if (!q || !q.question || !Array.isArray(q.memo) || !q.memo.length) continue;
    const id = `${label}#${q.qnum}`;
    if (S.bank.some((b) => b.id === id)) continue;
    const memoSteps = q.memo.map((m) => ({ step: String(m.step), marks: Number(m.marks) || 0 }));
    const sum = memoSteps.reduce((a, m) => a + m.marks, 0);
    const topic = String(q.topic || 'Algebra, equations and inequalities');
    const skill = String(q.skill || 'General');
    S.bank.push({ id, source: label, qnum: String(q.qnum), topic, skill, level: clamp(Number(q.level) || 3, 1, 5), marks: sum || Number(q.marks) || 0, question: String(q.question), has_diagram: !!q.has_diagram, memo: memoSteps, final_answer: String(q.final_answer || ''), style: out.style_notes || '' });
    ensureSkill(topic, skill);
    added++;
  }
  S.papers.push({ id: uid(), name: label, addedAt: Date.now(), count: added, style: out.style_notes || '' });
  save();
  return added;
}

function styleExamples(topic, skill) {
  const same = S.bank.filter((q) => q.topic === topic).sort((a, b) => (a.skill === skill ? -1 : 0) - (b.skill === skill ? -1 : 0));
  return same.slice(0, 3).map((q) => `Marks ${q.marks}, level ${q.level}: ${q.question}`).join('\n---\n') || '(none)';
}

async function generateOnce(skillKey) {
  const s = S.skills[skillKey];
  const recentTags = Object.entries(s.errors).sort((a, b) => b[1] - a[1]).slice(0, 4).map(([t]) => t);
  const recentQs = S.attempts.filter((a) => a.skillKey === skillKey).slice(-5).map((a) => a.question).filter(Boolean);
  const pressing = !!s.failedAt;
  const text = `Write one new exam-style question for this skill.
Topic: ${s.topic}
Skill: ${s.skill}
Difficulty level ${s.level} of 5: ${LEVELS[s.level]}
${pressing ? `The student has FAILED this skill at this level. Press on the weakness. Use a different phrasing, context or structure from the questions listed below, while testing the same underlying skill.` : 'Make it a fresh question in the style of the examples.'}
Mistakes this student keeps making: ${recentTags.length ? recentTags.join(', ') : 'none recorded yet'}. Design the question so those mistakes would show up if the student still makes them.

Style examples taken from the student's own papers:
${styleExamples(s.topic, s.skill)}

Questions already given recently (do not repeat or lightly reword these):
${recentQs.join('\n---\n') || '(none)'}

Constraints:
- The question must be answerable from text alone. No diagrams, graphs or figures.
- It must have a single unambiguous correct answer or answers.
- Provide a complete memorandum split into lines with a mark for each line, the marks adding up to the total.

Return {"question":"...","marks":n,"memo":[{"step":"...","marks":n}],"final_answer":"...","form":"a few words describing how the question is framed"}.`;
  const g = await askJson({ system: BASE, maxTokens: 3000, parts: [{ type: 'text', text }] });
  if (!g.question || !Array.isArray(g.memo) || !g.memo.length) throw new ApiError('The model returned an incomplete question. Try again.');
  const memo = g.memo.map((m) => ({ step: String(m.step), marks: Number(m.marks) || 0 }));
  return { question: String(g.question), memo, marks: memo.reduce((a, m) => a + m.marks, 0), final_answer: String(g.final_answer || ''), form: String(g.form || '') };
}

async function verifyQuestion(g) {
  const solved = await askJson({
    system: BASE,
    maxTokens: 3000,
    parts: [{ type: 'text', text: `Solve this question completely and carefully, from scratch. Check your answer by substituting back where possible.\n\n${g.question}\n\nReturn {"final_answer":"...","working":"brief working"}.` }],
  });
  const cmp = await askJson({
    system: BASE,
    maxTokens: 800,
    parts: [{ type: 'text', text: `Question:\n${g.question}\n\nAnswer A (examiner's memo): ${g.final_answer}\nAnswer B (independent solution): ${solved.final_answer}\n\nDo A and B agree mathematically? Equivalent forms count as agreeing. Different rounding counts as agreeing only if both fit any accuracy the question asks for. Return {"agree":true or false,"note":"one sentence"}.` }],
  });
  return !!cmp.agree;
}

async function generateQuestion(skillKey, setStatus) {
  const tries = S.settings.verify ? 3 : 1;
  let last;
  for (let i = 0; i < tries; i++) {
    setStatus && setStatus(i === 0 ? 'Writing a question aimed at your weak point...' : `Answer check failed, writing another (${i + 1} of ${tries})...`);
    last = await generateOnce(skillKey);
    if (!S.settings.verify) return { ...last, verified: false, checked: false };
    setStatus && setStatus('Checking the memorandum by solving it independently...');
    if (await verifyQuestion(last)) return { ...last, verified: true, checked: true };
  }
  return { ...last, verified: false, checked: true };
}

async function prepareQuestion(skillKey, setStatus) {
  const s = S.skills[skillKey];
  const unseen = S.bank.filter((q) => skillKeyOf(q) === skillKey && !q.has_diagram && !S.seen.includes(q.id) && q.id !== session?.current?.bankId && Math.abs(q.level - s.level) <= 1);
  let item;
  if (unseen.length && !s.failedAt && Math.random() < 0.5) {
    const q = unseen[Math.floor(Math.random() * unseen.length)];
    item = { question: q.question, marks: q.marks, memo: q.memo, final_answer: q.final_answer, form: q.source + ' ' + q.qnum, verified: true, checked: false, bankId: q.id, fromPaper: true };
  } else {
    item = await generateQuestion(skillKey, setStatus);
  }
  return { ...item, key: skillKey, topic: s.topic, skill: s.skill, level: s.level };
}

async function markWork(cur, images, typed, extra) {
  const memoText = cur.memo.map((m, i) => `Line ${i + 1} (${m.marks} mark${m.marks === 1 ? '' : 's'}): ${m.step}`).join('\n');
  const tags = Object.values(S.skills).flatMap((s) => Object.keys(s.errors)).filter((v, i, a) => a.indexOf(v) === i).slice(0, 30).join(', ') || '(none yet)';
  const text = `Mark this student's handwritten working against the memorandum.

Question (${cur.marks} marks):
${cur.question}

Memorandum:
${memoText}
Final answer: ${cur.final_answer}

${typed ? `The student typed this as their final answer: ${typed}\n` : ''}${extra || ''}
Method:
1. First transcribe the student's working line by line, faithfully, including any mistakes. Do not correct it while transcribing. If a part is unreadable, say so rather than guessing, and set "legible" to false if you cannot mark fairly.
2. Mark using the memorandum. Award method marks for any valid alternative method. Apply consistent accuracy: do not penalise the student again for an error that was carried forward from an earlier line.
3. Identify the FIRST line where the student's working goes wrong.
4. Name each distinct error with a short snake_case tag naming the mistake itself, for example sign_error_expanding, forgot_to_reject_negative_root, wrong_quadrant. Reuse a tag from this list when it fits: ${tags}.

Return:
{"legible":true,"transcription":[{"line":1,"text":"...","ok":true,"comment":"empty if fine, otherwise what is wrong"}],
"awarded":[{"line":1,"marks":n,"reason":"short"}],
"first_error":null or {"line":n,"what":"what went wrong","fix":"the correct step"},
"error_tags":["..."],
"confidence":"high" | "medium" | "low"}
"awarded" must have one entry per memorandum line, in order, with "line" being the memorandum line number and never more marks than that line carries.`;
  const parts = images.map((im) => ({ type: 'image', mime: im.mime, data: im.data }));
  parts.push({ type: 'text', text });
  const r = await askJson({ system: BASE, maxTokens: 4000, parts });
  return normaliseMarking(cur, r);
}

function normaliseMarking(cur, r) {
  const awarded = cur.memo.map((m, i) => {
    const a = (r.awarded || []).find((x) => Number(x.line) === i + 1) || (r.awarded || [])[i] || {};
    return { line: i + 1, step: m.step, max: m.marks, marks: clamp(Number(a.marks) || 0, 0, m.marks), reason: String(a.reason || '') };
  });
  const total = awarded.reduce((a, x) => a + x.marks, 0);
  return {
    legible: r.legible !== false,
    transcription: (r.transcription || []).map((t, i) => ({ line: Number(t.line) || i + 1, text: String(t.text ?? ''), ok: t.ok !== false, comment: String(t.comment || '') })),
    awarded, total,
    first_error: r.first_error && r.first_error.what ? { line: Number(r.first_error.line) || null, what: String(r.first_error.what), fix: String(r.first_error.fix || '') } : null,
    tags: (r.error_tags || []).map((t) => String(t).toLowerCase().replace(/[^a-z0-9_]+/g, '_').replace(/^_|_$/g, '')).filter(Boolean).slice(0, 5),
    confidence: r.confidence || 'medium',
  };
}

/* ---------- adaptive engine ---------- */
function passFrac(res, marks) { return marks ? res.total / marks : 0; }

function commitAttempt(cur, res, meta) {
  const s = S.skills[cur.key];
  const frac = passFrac(res, cur.marks);
  const failed = frac < 0.5;
  s.attempts++;
  s.mastery = clamp(s.mastery * 0.6 + frac * 0.4, 0, 1);
  s.last = Date.now();
  if (frac >= 0.75) {
    s.streak++; s.failStreak = 0;
    if (!s.failedAt) s.level = Math.min(5, s.level + 1);
    else if (s.streak >= 2) { s.level = Math.min(5, s.level + 1); s.failedAt = null; s.streak = 0; }
  } else if (failed) {
    s.failedAt = s.level; s.streak = 0; s.failStreak++;
    if (s.failStreak >= 3 && s.level > 1) { s.level--; s.failedAt = s.level; s.failStreak = 0; }
  } else { s.streak = 0; s.failStreak = 0; }
  if (!res.tags) res.tags = [];
  if (failed || frac < 0.75) res.tags.forEach((t) => { s.errors[t] = (s.errors[t] || 0) + 1; });
  if (cur.bankId && !S.seen.includes(cur.bankId)) S.seen.push(cur.bankId);
  S.attempts.push({ t: Date.now(), skillKey: cur.key, level: cur.level, marks: res.total, out_of: cur.marks, tags: res.tags, firstError: res.first_error ? res.first_error.what : '', question: cur.question.slice(0, 600), generated: !cur.fromPaper, disputed: !!meta.disputed, overridden: !!meta.overridden });
  if (S.attempts.length > 600) S.attempts = S.attempts.slice(-600);
  save();
  return { frac, failed };
}

function pickSkill(excludeKey, lastKey) {
  const keys = Object.keys(S.skills).filter((k) => k !== excludeKey);
  if (!keys.length) return excludeKey || null;
  const ws = keys.map((k) => {
    const s = S.skills[k];
    let w = 0.15 + 2 * Math.pow(1 - s.mastery, 2);
    if (s.failedAt) w += 1;
    if (!s.attempts) w += 0.6;
    if (k === lastKey) w *= 0.5;
    return w;
  });
  let r = Math.random() * ws.reduce((a, b) => a + b, 0);
  for (let i = 0; i < keys.length; i++) { r -= ws[i]; if (r <= 0) return keys[i]; }
  return keys[keys.length - 1];
}

/* ---------- session ---------- */
let session = null;
let ui = { tab: 'session' };

function startSession(focusKey) {
  if (!activeKey()) { toast('Add your API key in Settings first.'); return showTab('settings'); }
  if (!Object.keys(S.skills).length) { toast('Add a paper and memorandum in Library first.'); return showTab('library'); }
  const mins = S.settings.minutes;
  session = { startedAt: Date.now(), endsAt: Date.now() + mins * 60000, minutes: mins, focus: focusKey || null, phase: 'loading', status: 'Choosing what to press...', current: null, results: [], lastKey: null, pressCount: 0, queuedKey: null, queuedP: null, error: null };
  renderSession();
  startTimer();
  nextQuestion();
}

let timerHandle;
function startTimer() {
  clearInterval(timerHandle);
  timerHandle = setInterval(() => {
    if (!session) return clearInterval(timerHandle);
    const left = session.endsAt - Date.now();
    const el = $('#timer');
    if (el) {
      const m = Math.max(0, Math.floor(left / 60000)), s = Math.max(0, Math.floor((left % 60000) / 1000));
      el.textContent = `${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`;
      el.classList.toggle('low', left < 120000);
    }
    if (left <= 0 && !session.over) { session.over = true; const n = $('#timeup'); if (n) n.hidden = false; }
  }, 1000);
}

function setStatus(msg) {
  if (!session) return;
  session.status = msg;
  const el = $('#status');
  if (el) el.textContent = msg;
}

async function nextQuestion() {
  const sess = session;
  sess.phase = 'loading'; sess.error = null; sess.status = 'Choosing what to press...';
  renderSession();
  try {
    const last = sess.results[sess.results.length - 1];
    const press = !sess.focus && last && S.skills[last.key].failedAt && sess.pressCount < 4;
    const key = sess.focus || (press ? last.key : (sess.queuedKey || pickSkill(null, sess.lastKey)));
    sess.pressCount = press ? sess.pressCount + 1 : 0;
    let item = null;
    if (sess.queuedP && sess.queuedKey === key) {
      setStatus('Loading the next question...');
      item = await sess.queuedP.catch(() => null);
      if (item && item.level !== S.skills[key].level) item = null;
    }
    if (sess === session && sess.queuedKey === key) { sess.queuedP = null; sess.queuedKey = null; }
    if (!item) item = await prepareQuestion(key, setStatus);
    if (sess !== session) return;
    sess.current = { ...item, images: [], typed: '' };
    sess.lastKey = key;
    sess.phase = 'question';
    prefetch(sess, key);
  } catch (e) {
    if (sess !== session) return;
    sess.phase = 'error'; sess.error = e.message || String(e);
  }
  renderSession();
}

function prefetch(sess, currentKey) {
  const key = sess.focus || pickSkill(currentKey, currentKey);
  if (!key) return;
  sess.queuedKey = key;
  sess.queuedP = prepareQuestion(key, () => {});
  sess.queuedP.catch(() => {});
}

async function submitWork() {
  const sess = session, cur = sess.current;
  if (!cur.images.length) return toast('Add a photo of your working first.');
  sess.phase = 'marking'; sess.status = 'Reading your handwriting and marking against the memorandum...';
  renderSession();
  try {
    const res = await markWork(cur, cur.images, cur.typed.trim());
    if (sess !== session) return;
    cur.result = res;
    cur.meta = { disputed: false, overridden: false };
    sess.phase = res.legible ? 'result' : 'unreadable';
  } catch (e) {
    if (sess !== session) return;
    sess.phase = 'question'; toast(e.message || 'Marking failed. Try again.');
  }
  renderSession();
}

async function disputeMarking(note) {
  const sess = session, cur = sess.current;
  sess.phase = 'marking'; sess.status = 'Re-marking with your objection...';
  renderSession();
  try {
    const prev = cur.result;
    const extra = `The student disputes the first marking.
Previous transcription and marks: ${JSON.stringify({ transcription: prev.transcription, awarded: prev.awarded.map((a) => ({ line: a.line, marks: a.marks })) })}
Student's objection: ${note || '(no reason given)'}
Re-mark from the images, independently. Re-read the handwriting rather than trusting the earlier transcription. Change the marks only where the working justifies it.`;
    const res = await markWork(cur, cur.images, cur.typed.trim(), extra);
    if (sess !== session) return;
    cur.result = res; cur.meta.disputed = true;
  } catch (e) { toast(e.message || 'Re-marking failed.'); }
  if (sess === session) { sess.phase = 'result'; renderSession(); }
}

function finishQuestion() {
  const sess = session, cur = sess.current;
  const out = commitAttempt(cur, cur.result, cur.meta);
  sess.results.push({ key: cur.key, skill: cur.skill, topic: cur.topic, level: cur.level, marks: cur.result.total, out_of: cur.marks, failed: out.failed, firstError: cur.result.first_error?.what || '' });
  if (sess.over || Date.now() >= sess.endsAt) { sess.phase = 'summary'; clearInterval(timerHandle); renderSession(); }
  else nextQuestion();
}

function endSession() {
  if (!session) return;
  if (session.phase === 'result' || session.phase === 'unreadable') {
    if (session.phase === 'result') { const cur = session.current; commitAttempt(cur, cur.result, cur.meta); session.results.push({ key: cur.key, skill: cur.skill, topic: cur.topic, level: cur.level, marks: cur.result.total, out_of: cur.marks, failed: passFrac(cur.result, cur.marks) < 0.5, firstError: cur.result.first_error?.what || '' }); }
  }
  clearInterval(timerHandle);
  if (!session.results.length) { session = null; } else { session.phase = 'summary'; }
  renderSession();
}

/* ---------- rendering: session ---------- */
function gaugeHTML(s) {
  let h = '<span class="gauge" role="img" aria-label="' + `Level ${s.level} of 5${s.failedAt ? ', failed at level ' + s.failedAt : ''}` + '">';
  for (let i = 1; i <= 5; i++) h += `<i class="${s.failedAt === i ? 'broke' : (i <= s.level ? 'on' : '')}"></i>`;
  return h + '</span>';
}

function renderSession() {
  const el = $('#view-session');
  if (!session) { el.innerHTML = idleHTML(); return; }
  const s = session;
  const cur = s.current;
  const head = `<div class="panel tight statusbar">
      <div class="row">${cur ? `<span class="chip">${esc(cur.topic)}</span><b>${esc(cur.skill)}</b> ${gaugeHTML(S.skills[cur.key])}` : '<span class="muted">Maths to Failure session</span>'}</div>
      <div class="row"><span class="timer" id="timer">--:--</span><button class="btn ghost" data-action="end">End session</button></div>
    </div>
    <div class="callout" id="timeup" ${s.over ? '' : 'hidden'}>Time is up. Finish the question you are on and submit it, then you will see your summary.</div>`;
  let body = '';
  if (s.phase === 'loading' || s.phase === 'marking') {
    body = `<div class="panel"><h2>${s.phase === 'marking' ? 'Marking' : 'Preparing'}</h2><div class="rig"></div><p class="muted" id="status">${esc(s.status)}</p></div>`;
  } else if (s.phase === 'error') {
    body = `<div class="panel"><h2>Something went wrong</h2><div class="callout">${esc(s.error)}</div><p></p><div class="row"><button class="btn" data-action="retry">Try again</button><button class="btn ghost" data-action="end">End session</button></div></div>`;
  } else if (s.phase === 'question') {
    body = questionHTML(cur);
  } else if (s.phase === 'unreadable') {
    body = `<div class="panel"><h2>Could not read your work</h2><div class="callout">The handwriting was not clear enough to mark fairly. No marks were recorded. Retake the photo with more light, the page flat, and the writing filling the frame.</div><p></p><button class="btn" data-action="retake">Add a new photo</button></div>`;
  } else if (s.phase === 'result') {
    body = resultHTML(cur);
  } else if (s.phase === 'summary') {
    body = summaryHTML();
  }
  el.innerHTML = (s.phase === 'summary' ? '' : head) + body;
  if (s.phase !== 'summary') tickNow();
  typeset(el);
}
function tickNow() { if (session) { const left = session.endsAt - Date.now(); const el = $('#timer'); if (el) { const m = Math.max(0, Math.floor(left / 60000)), sec = Math.max(0, Math.floor((left % 60000) / 1000)); el.textContent = `${String(m).padStart(2, '0')}:${String(sec).padStart(2, '0')}`; el.classList.toggle('low', left < 120000); } } }

function idleHTML() {
  const skills = Object.values(S.skills);
  const weak = skills.filter((x) => x.failedAt).length;
  const ready = activeKey() && skills.length;
  return `<div class="panel">
      <h2>Press until it breaks</h2>
      <p>Pick a time limit. The app finds the skills you are weakest at, raises the difficulty step by step, and when you fail it keeps asking about that exact skill in new forms until you hold it.</p>
      <div class="field"><span class="lab">Time limit</span>
        <div class="seg" id="mins">${[15, 30, 45, 60].map((m) => `<button data-mins="${m}" class="${S.settings.minutes === m ? 'on' : ''}">${m} min</button>`).join('')}</div></div>
      <p></p>
      <div class="row"><button class="btn big" data-action="start" ${ready ? '' : 'disabled'}>Start session</button>
      <span class="muted small">${skills.length} skills from ${S.bank.length} questions${weak ? `, ${weak} currently at a failure point` : ''}</span></div>
      ${ready ? '' : `<p></p><div class="callout">${!activeKey() ? 'Add your API key in Settings. ' : ''}${!skills.length ? 'Add a question paper and its memorandum in Library so the app can learn your question style.' : ''}</div>`}
    </div>
    <div class="panel tight muted small">Marking is done by an AI model reading your photo. It uses your memorandum, but it can still make mistakes. If a mark looks wrong, use the disagree button on the result screen.</div>`;
}

function questionHTML(cur) {
  const over = session.over;
  return `<article class="panel">
      <div class="qmeta"><span class="chip">Level ${cur.level}</span>${cur.fromPaper ? `<span class="chip pass">From ${esc(cur.form)}</span>` : '<span class="chip">New question</span>'}${cur.checked && !cur.verified ? '<span class="chip warn" title="The answer check disagreed with the memo three times">Answer unconfirmed</span>' : ''}<span class="marks">[${cur.marks}]</span></div>
      <div class="qtext" id="qtext">${esc(cur.question)}</div>
    </article>
    <section class="panel">
      <h3>Your working</h3>
      <p class="muted">Write the full solution on your iPad or on paper, then add a photo or screenshot. Add several images in order if it runs over.</p>
      <div class="row"><label class="btn ghost" for="photo">Add photo or screenshot</label><input type="file" id="photo" accept="image/*" multiple hidden></div>
      <div class="previews" id="previews">${previewsHTML(cur)}</div>
      <div class="field"><label for="typed">Final answer, typed (optional)</label><input type="text" id="typed" value="${esc(cur.typed)}" autocomplete="off"></div>
      <p></p>
      <button class="btn big" data-action="submit">${over ? 'Submit and finish' : 'Submit for marking'}</button>
    </section>`;
}
function previewsHTML(cur) {
  return cur.images.map((im, i) => `<figure><img src="${im.url}" alt="Working page ${i + 1}"><button data-rm="${i}" aria-label="Remove image ${i + 1}">&times;</button></figure>`).join('');
}

function resultHTML(cur) {
  const r = cur.result;
  const frac = passFrac(r, cur.marks);
  const sk = S.skills[cur.key];
  const verdict = frac >= 0.75 ? ['pass', 'Held. Difficulty goes up.'] : frac < 0.5 ? ['fail', 'Failure point. This skill gets pressed next.'] : ['', 'Partly there. Same level again.'];
  const lines = r.transcription.map((t) => `<div class="line ${t.ok ? '' : 'bad'}"><span class="n">${t.line}</span><span class="t">${esc(t.text)}</span>${t.comment ? `<span class="c">${esc(t.comment)}</span>` : ''}</div>`).join('');
  const fe = r.first_error ? `<div class="callout"><b>First mistake${r.first_error.line ? `, line ${r.first_error.line}` : ''}</b><p>${esc(r.first_error.what)}</p>${r.first_error.fix ? `<p><span class="lab">Correct step</span><br>${esc(r.first_error.fix)}</p>` : ''}</div>` : '<div class="callout" style="border-color:var(--pass);background:var(--pass-bg)">No errors found in your working.</div>';
  const steps = r.awarded.map((a) => `<tr><td>${a.line}</td><td>${esc(a.reason || a.step)}</td><td>${a.marks}/${a.max}</td></tr>`).join('');
  return `<article class="panel">
      <div class="row between"><div><div class="score">${r.total}<small> / ${cur.marks}</small></div><span class="chip ${verdict[0]}">${verdict[1]}</span></div><div>${gaugeHTML(sk)}<div class="muted small">After this answer the level may change</div></div></div>
      ${r.confidence === 'low' ? '<p></p><div class="chip warn">Low marking confidence. Check the transcription below.</div>' : ''}
    </article>
    ${fe}
    <section class="panel"><h3>What the marker read from your work</h3>
      <p class="muted small">If a line is misread, the marks may be wrong. Use the buttons below to dispute or set your own mark.</p>
      <div class="lines">${lines || '<span class="muted">No transcription returned.</span>'}</div></section>
    <section class="panel"><h3>Mark breakdown</h3><div class="table-wrap"><table class="steps"><thead><tr><th>#</th><th>Awarded for</th><th>Marks</th></tr></thead><tbody>${steps}</tbody></table></div>
      <details><summary>Show the memorandum</summary>${cur.memo.map((m, i) => `<p><span class="mono">${i + 1}.</span> ${esc(m.step)} <span class="mono muted">[${m.marks}]</span></p>`).join('')}<p><b>Final answer:</b> ${esc(cur.final_answer)}</p></details></section>
    <section class="panel"><div class="row">
        <button class="btn big" data-action="finish">${session.over ? 'Finish session' : 'Next question'}</button>
        <button class="btn ghost" data-action="dispute-open">I disagree with the marking</button>
        <button class="btn ghost" data-action="override-open">Set my own mark</button></div>
      <div id="dispute" hidden><p></p><div class="field"><label for="dnote">Why do you disagree?</label><textarea id="dnote" placeholder="For example: line 3 says x = 4 but I wrote x = -4"></textarea></div><p></p><button class="btn" data-action="dispute-go">Re-mark</button></div>
      <div id="override" hidden><p></p><div class="field"><label for="onum">Your mark (0 to ${cur.marks})</label><input type="number" id="onum" min="0" max="${cur.marks}" value="${r.total}"></div><p></p><button class="btn" data-action="override-go">Use this mark</button><p class="muted small">Self-assessed marks are recorded as overridden.</p></div>
    </section>`;
}

function summaryHTML() {
  const r = session.results;
  const tot = r.reduce((a, x) => a + x.marks, 0), out = r.reduce((a, x) => a + x.out_of, 0);
  const fails = r.filter((x) => x.failed);
  const mins = Math.max(1, Math.round((Date.now() - session.startedAt) / 60000));
  const rows = r.map((x) => `<tr><td>${esc(x.skill)}<br><span class="muted small">${esc(x.topic)}, level ${x.level}</span></td><td>${x.marks}/${x.out_of}</td></tr>`).join('');
  return `<div class="panel"><h2>Session summary</h2>
      <div class="row between"><div><div class="score">${tot}<small> / ${out}</small></div><span class="muted">${r.length} questions in ${mins} min</span></div>
      <div class="chip ${fails.length ? 'fail' : 'pass'}">${fails.length} failure point${fails.length === 1 ? '' : 's'} found</div></div></div>
    ${fails.length ? `<div class="panel"><h3>Where you broke</h3>${fails.map((f) => `<p><b>${esc(f.skill)}</b> (level ${f.level})${f.firstError ? `<br><span class="muted">${esc(f.firstError)}</span>` : ''}</p>`).join('')}</div>` : ''}
    <div class="panel"><h3>Questions</h3><div class="table-wrap"><table class="steps"><tbody>${rows}</tbody></table></div></div>
    <div class="row"><button class="btn big" data-action="done">Back to start</button><button class="btn ghost" data-action="goto-progress">See weak spots</button></div>`;
}

/* ---------- rendering: progress ---------- */
function renderProgress() {
  const el = $('#view-progress');
  const skills = Object.entries(S.skills);
  if (!skills.length) { el.innerHTML = '<div class="panel"><h2>Weak spots</h2><p class="muted">Nothing yet. Add a paper in Library, then do a session.</p></div>'; return; }
  const worst = skills.filter(([, s]) => s.attempts).sort((a, b) => a[1].mastery - b[1].mastery).slice(0, 3);
  const byTopic = {};
  skills.forEach(([k, s]) => { (byTopic[s.topic] = byTopic[s.topic] || []).push([k, s]); });
  const topics = Object.keys(byTopic).sort();
  el.innerHTML = `<div class="panel"><h2>Weak spots</h2>
      ${worst.length ? `<p class="muted">Weakest right now. Press one directly.</p>${worst.map(([k, s]) => `<div class="row between" style="padding:.3rem 0"><span><b>${esc(s.skill)}</b> <span class="muted small">${esc(s.topic)}</span></span><button class="btn" data-press="${esc(k)}">Press this</button></div>`).join('')}` : '<p class="muted">Finish a session to see your weakest skills.</p>'}</div>
    ${topics.map((t) => `<div class="panel"><h3>${esc(t)}</h3>${byTopic[t].sort((a, b) => a[1].mastery - b[1].mastery).map(([k, s]) => {
      const errs = Object.entries(s.errors).sort((a, b) => b[1] - a[1]).slice(0, 4);
      return `<div class="skill"><div class="nm">${esc(s.skill)}</div><div>${gaugeHTML(s)}</div>
        <div class="meta"><div class="meter ${s.mastery < 0.5 ? 'low' : ''}" style="width:120px"><b style="width:${pct(s.mastery)}%"></b></div><span class="mono small">${s.attempts ? pct(s.mastery) + '%' : 'untested'}</span><span class="muted small">${s.attempts} attempt${s.attempts === 1 ? '' : 's'}</span>${s.failedAt ? `<span class="chip fail">failed at level ${s.failedAt}</span>` : ''}${errs.map(([tg, n]) => `<span class="tag">${esc(tg)} x${n}</span>`).join('')}</div></div>`;
    }).join('')}</div>`).join('')}
    <div class="panel"><h3>Recent attempts</h3>${S.attempts.slice(-8).reverse().map((a) => `<p class="small"><b>${a.marks}/${a.out_of}</b> ${esc(S.skills[a.skillKey]?.skill || a.skillKey)} <span class="muted">level ${a.level}${a.disputed ? ', disputed' : ''}${a.overridden ? ', self-marked' : ''}</span>${a.firstError ? `<br><span class="muted">${esc(a.firstError)}</span>` : ''}</p>`).join('') || '<p class="muted">No attempts yet.</p>'}</div>`;
  typeset(el);
}

/* ---------- rendering: library ---------- */
let libLog = '';
function renderLibrary() {
  const el = $('#view-library');
  const diag = S.bank.filter((q) => q.has_diagram).length;
  el.innerHTML = `<div class="panel"><h2>Library</h2>
      <p>Upload a question paper and its memorandum as PDFs. The app extracts every question and its mark allocation, tags topic and skill, and learns how IEB phrases things. The PDFs are not stored. Only the extracted text is kept on this device.</p>
      <div class="grid2">
        <div class="field"><label for="plabel">Name</label><input type="text" id="plabel" placeholder="e.g. 2023 Paper 1"></div>
        <div class="field"><label for="prange">Questions to extract (optional)</label><input type="text" id="prange" placeholder="e.g. 1 to 4"></div>
        <div class="field"><label for="ppaper">Question paper (PDF)</label><input type="file" id="ppaper" accept="application/pdf"></div>
        <div class="field"><label for="pmemo">Memorandum (PDF)</label><input type="file" id="pmemo" accept="application/pdf"></div>
      </div><p></p>
      <button class="btn" id="ingest" data-action="ingest">Extract questions</button>
      <p class="muted small">Long papers can overflow the model's reply. Extract 3 to 5 questions at a time using the range box, with the same name each time.</p>
      <div class="log" id="liblog" ${libLog ? '' : 'hidden'}>${esc(libLog)}</div></div>
    <div class="panel"><h3>Your papers</h3>
      ${S.papers.length ? S.papers.map((p) => `<div class="row between" style="padding:.3rem 0"><span><b>${esc(p.name)}</b> <span class="muted small">${p.count} questions</span></span><button class="btn danger" data-delpaper="${esc(p.id)}">Remove</button></div>`).join('') : '<p class="muted">No papers yet.</p>'}
      <p class="muted small">${S.bank.length} questions in your bank${diag ? `. ${diag} need a figure, so they are used as style examples only, not asked directly` : ''}.</p></div>`;
}

/* ---------- rendering: settings ---------- */
function renderSettings() {
  const st = S.settings;
  const el = $('#view-settings');
  el.innerHTML = `<div class="panel"><h2>Settings</h2>
      <div class="field"><span class="lab">Model provider</span><div class="seg" id="prov"><button data-prov="claude" class="${st.provider === 'claude' ? 'on' : ''}">Claude</button><button data-prov="gemini" class="${st.provider === 'gemini' ? 'on' : ''}">Gemini</button></div></div><p></p>
      <div class="grid2">
        <div class="field"><label for="ckey">Claude API key</label><input type="password" id="ckey" value="${esc(st.claudeKey)}" autocomplete="off" placeholder="sk-ant-..."></div>
        <div class="field"><label for="cmodel">Claude model</label><input type="text" id="cmodel" value="${esc(st.claudeModel)}"></div>
        <div class="field"><label for="gkey">Gemini API key</label><input type="password" id="gkey" value="${esc(st.geminiKey)}" autocomplete="off" placeholder="AIza..."></div>
        <div class="field"><label for="gmodel">Gemini model</label><input type="text" id="gmodel" value="${esc(st.geminiModel)}"></div>
      </div><p></p>
      <label class="row" style="gap:.6rem"><input type="checkbox" id="verify" ${st.verify ? 'checked' : ''} style="width:22px;height:22px"><span>Check generated questions by solving them a second time (slower, but catches wrong memorandums)</span></label><p></p>
      <div class="row"><button class="btn" data-action="savekeys">Save</button><button class="btn ghost" data-action="testkey">Test connection</button></div>
      <p></p><p class="muted small">Your key is stored only in this browser and sent only to ${st.provider === 'claude' ? 'api.anthropic.com' : 'generativelanguage.googleapis.com'}. The page blocks requests to any other site. Do not use this app on a shared or public device. Model names change over time, so edit them here if a call fails with a "model not found" error.</p></div>
    <div class="panel"><h3>Your data</h3>
      <p class="muted">Browsers can wipe stored data, and Safari does so for sites you have not opened in a week unless the app is added to your home screen. Export a backup now and then. The backup never includes your API keys.</p>
      <div class="row"><button class="btn ghost" data-action="export">Export backup</button><label class="btn ghost" for="import">Import backup</label><input type="file" id="import" accept="application/json" hidden><button class="btn danger" data-action="reset">Erase everything</button></div>
      <div id="resetconfirm" hidden><p></p><div class="callout">This deletes your papers, progress and keys from this browser.<p></p><button class="btn danger" data-action="reset-go">Yes, erase everything</button></div></div></div>`;
}

/* ---------- navigation ---------- */
function showTab(name) {
  ui.tab = name;
  $$('#tabs button').forEach((b) => b.classList.toggle('on', b.dataset.tab === name));
  ['session', 'progress', 'library', 'settings'].forEach((v) => { $('#view-' + v).hidden = v !== name; });
  if (name === 'session') renderSession();
  if (name === 'progress') renderProgress();
  if (name === 'library') renderLibrary();
  if (name === 'settings') renderSettings();
}

/* ---------- events ---------- */
document.addEventListener('click', async (e) => {
  const t = e.target.closest('button, [data-tab]');
  if (!t) return;
  if (t.dataset.tab) return showTab(t.dataset.tab);
  if (t.dataset.mins) { S.settings.minutes = Number(t.dataset.mins); save(); return renderSession(); }
  if (t.dataset.prov) { S.settings.provider = t.dataset.prov; save(); return renderSettings(); }
  if (t.dataset.rm !== undefined) { session.current.images.splice(Number(t.dataset.rm), 1); $('#previews').innerHTML = previewsHTML(session.current); return; }
  if (t.dataset.press) { showTab('session'); return startSession(t.dataset.press); }
  if (t.dataset.delpaper) {
    const p = S.papers.find((x) => x.id === t.dataset.delpaper);
    if (p) { S.bank = S.bank.filter((q) => q.source !== p.name); S.papers = S.papers.filter((x) => x.name !== p.name); pruneSkills(); save(); renderLibrary(); }
    return;
  }
  switch (t.dataset.action) {
    case 'start': return startSession();
    case 'end': return endSession();
    case 'retry': return nextQuestion();
    case 'retake': session.phase = 'question'; return renderSession();
    case 'submit': return submitWork();
    case 'finish': return finishQuestion();
    case 'done': session = null; clearInterval(timerHandle); return renderSession();
    case 'goto-progress': session = null; return showTab('progress');
    case 'dispute-open': $('#dispute').hidden = !$('#dispute').hidden; return;
    case 'dispute-go': return disputeMarking($('#dnote').value.trim());
    case 'override-open': $('#override').hidden = !$('#override').hidden; return;
    case 'override-go': return overrideMarks(Number($('#onum').value));
    case 'ingest': return doIngest();
    case 'savekeys': return saveSettings();
    case 'testkey': return testKey();
    case 'export': return exportData();
    case 'reset': $('#resetconfirm').hidden = false; return;
    case 'reset-go': localStorage.removeItem(STORE_KEY); S = defaults(); session = null; toast('Everything erased.'); return showTab('settings');
  }
});

document.addEventListener('change', async (e) => {
  if (e.target.id === 'photo') {
    const cur = session && session.current;
    if (!cur) return;
    for (const f of Array.from(e.target.files)) {
      try { cur.images.push(await imageToJpeg(f)); } catch (err) { toast(err.message); }
    }
    e.target.value = '';
    $('#previews').innerHTML = previewsHTML(cur);
  }
  if (e.target.id === 'import') {
    const f = e.target.files[0];
    if (!f) return;
    try {
      const p = JSON.parse(await f.text());
      const d = defaults();
      const keep = { claudeKey: S.settings.claudeKey, geminiKey: S.settings.geminiKey };
      S = Object.assign(d, p, { settings: Object.assign(d.settings, p.settings || {}, keep) });
      save(); toast('Backup imported.'); renderSettings();
    } catch (err) { toast('That file is not a valid backup.'); }
  }
});
document.addEventListener('input', (e) => { if (e.target.id === 'typed' && session && session.current) session.current.typed = e.target.value; });

function pruneSkills() {
  const live = new Set(S.bank.map(skillKeyOf));
  Object.keys(S.skills).forEach((k) => { if (!live.has(k) && !S.skills[k].attempts) delete S.skills[k]; });
}

function overrideMarks(n) {
  const cur = session.current;
  if (!Number.isFinite(n)) return;
  const v = clamp(Math.round(n), 0, cur.marks);
  cur.result.total = v;
  cur.result.first_error = v >= cur.marks ? null : cur.result.first_error;
  cur.meta.overridden = true;
  renderSession();
  toast(`Mark set to ${v}.`);
}

async function doIngest() {
  const label = $('#plabel').value.trim();
  const range = $('#prange').value.trim();
  const fp = $('#ppaper').files[0], fm = $('#pmemo').files[0];
  const logEl = $('#liblog'), btn = $('#ingest');
  const log = (m) => { libLog = m; logEl.hidden = false; logEl.textContent = m; };
  if (!label || !fp || !fm) return toast('Give it a name and choose both PDFs.');
  if (fp.size + fm.size > 24 * 1024 * 1024) return toast('Those PDFs are too large together. Keep them under 24 MB.');
  btn.disabled = true;
  try {
    log('Uploading...');
    const [paper, memo] = [await fileToBase64(fp), await fileToBase64(fm)];
    const n = await ingestPaper({ label, paper, memo, range, log });
    log(`Done. Added ${n} question${n === 1 ? '' : 's'} from "${label}".${n === 0 ? ' Nothing new was found. If you already extracted these, they are skipped.' : ''}`);
    renderLibraryPapersOnly();
  } catch (e) { log('Failed: ' + (e.message || e)); }
  btn.disabled = false;
}
function renderLibraryPapersOnly() { const keep = libLog; renderLibrary(); libLog = keep; const l = $('#liblog'); if (l) { l.hidden = false; l.textContent = keep; } }

function saveSettings() {
  const st = S.settings;
  st.claudeKey = $('#ckey').value.trim(); st.geminiKey = $('#gkey').value.trim();
  st.claudeModel = $('#cmodel').value.trim() || DEFAULT_MODELS.claude;
  st.geminiModel = $('#gmodel').value.trim() || DEFAULT_MODELS.gemini;
  st.verify = $('#verify').checked;
  save(); toast('Saved.');
}
async function testKey() {
  saveSettings();
  try {
    const r = await askJson({ system: 'Reply with the JSON object {"ok":true} and nothing else.', parts: [{ type: 'text', text: 'ping' }], maxTokens: 50 });
    toast(r.ok ? 'Connected.' : 'Connected, but the reply was unexpected.');
  } catch (e) { toast(e.message || 'Connection failed.'); }
}
function exportData() {
  const copy = JSON.parse(JSON.stringify(S));
  copy.settings.claudeKey = ''; copy.settings.geminiKey = '';
  const a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob([JSON.stringify(copy)], { type: 'application/json' }));
  a.download = `maths-to-failure-backup-${new Date().toISOString().slice(0, 10)}.json`;
  document.body.appendChild(a); a.click(); a.remove();
}

/* ---------- boot ---------- */
window.addEventListener('DOMContentLoaded', () => {
  try { navigator.storage && navigator.storage.persist && navigator.storage.persist(); } catch (e) { /* optional */ }
  showTab(!activeKey() ? 'settings' : 'session');
});
window.addEventListener('load', () => { if (session) typeset($('#view-session')); });
