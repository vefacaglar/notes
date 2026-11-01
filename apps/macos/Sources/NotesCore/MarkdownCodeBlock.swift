import Foundation

public enum MarkdownCodeBlock {
    /// The code of a fenced block (`block` is the styler's `.codeBlock` range): its lines without the opening fence
    /// and, if the block is closed, without the closing fence; no break after the last line, `\n` between lines.
    public static func code(in text: String, block: NSRange) -> String {
        let ns = text as NSString
        guard block.location >= 0, NSMaxRange(block) <= ns.length else { return "" }
        var lines = ns.substring(with: block).components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        guard let open = lines.first.flatMap(fence) else { return "" }
        lines.removeFirst()
        if let last = lines.last, let close = fence(last), close.char == open.char, close.count >= open.count,
           last.drop(while: { $0 == " " || $0 == "\t" }).dropFirst(close.count).allSatisfy({ $0 == " " || $0 == "\t" }) {
            lines.removeLast()
        } else if lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    private static func fence(_ line: String) -> (char: Character, count: Int)? {
        let body = line.drop(while: { $0 == " " || $0 == "\t" })
        guard line.count - body.count <= 3, let char = body.first, char == "`" || char == "~" else { return nil }
        let count = body.prefix(while: { $0 == char }).count
        return count >= 3 ? (char, count) : nil
    }
}
