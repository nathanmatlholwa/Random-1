import Foundation

struct PickedPDF: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var data: Data
}

struct StagedPair: Identifiable {
    let id = UUID()
    var name: String
    var paper: PickedPDF?
    var memo: PickedPDF?
}

/// Matches question papers with their memorandums by file name, so many PDFs can be added at once.
enum PaperPairing {
    private static let memoWords: Set<String> = ["memo", "memorandum", "memos", "marking", "guideline", "guidelines",
                                                  "scheme", "mark", "answer", "answers", "solution", "solutions"]

    static func isMemo(_ filename: String) -> Bool {
        words(filename).contains { memoWords.contains($0) }
    }

    /// A name with the memo words removed, so "Paper 1 2023" and "Paper 1 2023 Memo" give the same key.
    static func baseKey(_ filename: String) -> String {
        words(filename).filter { !memoWords.contains($0) }.joined(separator: " ")
    }

    static func displayName(_ filename: String) -> String {
        let cleaned = words(filename).filter { !memoWords.contains($0) }
        return cleaned.isEmpty ? filename : cleaned.joined(separator: " ").capitalized
    }

    private static func words(_ filename: String) -> [String] {
        var name = filename
        if name.lowercased().hasSuffix(".pdf") { name = String(name.dropLast(4)) }
        var out: [String] = []
        var current = ""
        for ch in name.lowercased() {
            if ch.isLetter || ch.isNumber { current.append(ch) }
            else if !current.isEmpty { out.append(current); current = "" }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// Returns the pairs found, plus memorandums that matched no paper.
    static func pair(_ files: [PickedPDF]) -> (pairs: [StagedPair], spareMemos: [PickedPDF]) {
        let papers = files.filter { !isMemo($0.name) }
        var memos = files.filter { isMemo($0.name) }
        var pairs: [StagedPair] = []
        for p in papers {
            let key = baseKey(p.name)
            var staged = StagedPair(name: displayName(p.name), paper: p, memo: nil)
            if let i = memos.firstIndex(where: { baseKey($0.name) == key }) {
                staged.memo = memos.remove(at: i)
            }
            pairs.append(staged)
        }
        return (pairs, memos)
    }
}
