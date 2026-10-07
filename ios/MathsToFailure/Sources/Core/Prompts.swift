import Foundation

/// Prompt text. Raw strings are used so LaTeX backslashes stay literal.
enum Prompts {
    static let base = #"""
    You are a senior IEB Grade 12 Mathematics examiner and teacher in South Africa.
    Rules for all replies:
    - Reply with one JSON object and nothing else. No code fences, no commentary.
    - Write all mathematics in LaTeX inside $...$ (inline) or $$...$$ (display). Never use the dollar sign for money; write Rand amounts as R1 500.
    - Inside JSON strings every LaTeX backslash must be written as two backslashes, for example \\frac{1}{2}.
    - Use South African and IEB conventions, notation and mark allocation (method, accuracy and consistent accuracy marks).
    """#

    static func listQuestions() -> String {
        #"""
        Document 1 is an IEB Grade 12 Mathematics question paper. List the numbers of its top-level questions (Question 1, Question 2, and so on) in order.
        Return {"questions":["1","2","3"]}.
        """#
    }

    static func extract(numbers: [String], knownSkills: [String]) -> String {
        let known = knownSkills.isEmpty ? "(none yet)" : knownSkills.joined(separator: "\n")
        let topics = Topics.all.joined(separator: " | ")
        let which = numbers.joined(separator: ", ")
        return #"""
        Document 1 is an IEB Grade 12 Mathematics question paper. Document 2 is its memorandum.
        Extract only the questions numbered: \#(which). Include every sub-question inside them.

        Split into the smallest separately answerable parts (for example 4.1, 4.2, 4.3). Copy any shared stem or given information into each part so every part can be answered on its own.
        For each part return:
        - qnum: the number as printed, e.g. "4.2"
        - topic: one of exactly these: \#(topics)
        - skill: a short specific skill name (for example "Solve trig equations with a negative angle"). Reuse a name from the list below when it fits; only invent a new one when none does.
        - level: 1 to 5 where 1 is routine and 5 is the hardest problem solving
        - marks: total marks for the part
        - question: the full question text, self-contained, LaTeX for maths
        - has_diagram: true if the question cannot be answered without seeing a figure or graph, otherwise false. If true, still describe the figure in words inside question.
        - memo: array of {"step": what the memorandum says for this line, "marks": marks for that line}. The marks must add up to marks.
        - final_answer: the final answer(s) as a short string

        Also return style_notes: two sentences on how this paper phrases and structures its questions.

        Existing skill names:
        \#(known)

        Return {"questions":[...],"style_notes":"..."}.
        """#
    }

    static func generate(topic: String, skill: String, level: Int, pressing: Bool, challenge: Bool,
                         errorTags: [String], examples: String, recent: [String]) -> String {
        let desc = Engine.levelDescriptions[level] ?? ""
        let pressLine = pressing
            ? "The student has FAILED this skill at this level. Press on the weakness. Use a different phrasing, context or structure from the questions listed below, while testing the same underlying skill."
            : "Make it a fresh question in the style of the examples."
        let challengeLine = challenge
            ? "CHALLENGE MODE: make this a demanding, unfamiliar problem of the kind that ends an IEB paper. It may combine this skill with one or two others, and should need real insight, not a routine procedure."
            : ""
        let tags = errorTags.isEmpty ? "none recorded yet" : errorTags.joined(separator: ", ")
        let recentText = recent.isEmpty ? "(none)" : recent.joined(separator: "\n---\n")
        return #"""
        Write one new exam-style question for this skill.
        Topic: \#(topic)
        Skill: \#(skill)
        Difficulty level \#(level) of 5: \#(desc)
        \#(pressLine)
        \#(challengeLine)
        Mistakes this student keeps making: \#(tags). Design the question so those mistakes would show up if the student still makes them.

        Style examples taken from the student's own papers:
        \#(examples)

        Questions already given recently (do not repeat or lightly reword these):
        \#(recentText)

        Constraints:
        - The question must be answerable from text alone. No diagrams, graphs or figures.
        - It must have a single unambiguous correct answer or answers.
        - Provide a complete memorandum split into lines with a mark for each line, the marks adding up to the total.

        Return {"question":"...","marks":n,"memo":[{"step":"...","marks":n}],"final_answer":"...","form":"a few words describing how the question is framed"}.
        """#
    }

    static func solve(question: String) -> String {
        #"""
        Solve this question completely and carefully, from scratch. Check your answer by substituting back where possible.

        \#(question)

        Return {"final_answer":"...","working":"brief working"}.
        """#
    }

    static func compare(question: String, memoAnswer: String, independent: String) -> String {
        #"""
        Question:
        \#(question)

        Answer A (examiner's memo): \#(memoAnswer)
        Answer B (independent solution): \#(independent)

        Do A and B agree mathematically? Equivalent forms count as agreeing. Different rounding counts as agreeing only if both fit any accuracy the question asks for.
        Return {"agree":true or false,"note":"one sentence"}.
        """#
    }

    static func mark(question: String, marks: Int, memo: [MemoStep], finalAnswer: String,
                     typed: String, knownTags: [String], extra: String) -> String {
        let memoText = memo.enumerated().map { i, m in
            "Line \(i + 1) (\(m.marks) mark\(m.marks == 1 ? "" : "s")): \(m.step)"
        }.joined(separator: "\n")
        let typedLine = typed.isEmpty ? "" : "The student typed this as their final answer: \(typed)\n"
        let tags = knownTags.isEmpty ? "(none yet)" : knownTags.joined(separator: ", ")
        return #"""
        Mark this student's handwritten working against the memorandum.

        Question (\#(marks) marks):
        \#(question)

        Memorandum:
        \#(memoText)
        Final answer: \#(finalAnswer)

        \#(typedLine)\#(extra)
        Method:
        1. First transcribe the student's working line by line, faithfully, including any mistakes. Do not correct it while transcribing. If a part is unreadable, say so rather than guessing, and set "legible" to false if you cannot mark fairly.
        2. Mark using the memorandum. Award method marks for any valid alternative method. Apply consistent accuracy: do not penalise the student again for an error that was carried forward from an earlier line.
        3. Identify the FIRST line where the student's working goes wrong.
        4. Name each distinct error with a short snake_case tag naming the mistake itself, for example sign_error_expanding, forgot_to_reject_negative_root, wrong_quadrant. Reuse a tag from this list when it fits: \#(tags).

        Return:
        {"legible":true,"transcription":[{"line":1,"text":"...","ok":true,"comment":"empty if fine, otherwise what is wrong"}],
        "awarded":[{"line":1,"marks":n,"reason":"short"}],
        "first_error":null or {"line":n,"what":"what went wrong","fix":"the correct step"},
        "error_tags":["..."],
        "confidence":"high" | "medium" | "low"}
        "awarded" must have one entry per memorandum line, in order, with "line" being the memorandum line number and never more marks than that line carries.
        """#
    }
}
