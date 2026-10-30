import Foundation
import Testing
@testable import NotesCore

struct JSONFormatterTests {
    @Test func formatsNestedAndKeepsKeyOrder() throws {
        let input = #"{"z":1,"a":{"y":[1,2,{"k":"v"}],"b":{},"c":[]},"m":[[]],"e":"son"}"#
        #expect(try JSONFormatter.format(input) == """
        {
          "z": 1,
          "a": {
            "y": [
              1,
              2,
              {
                "k": "v"
              }
            ],
            "b": {},
            "c": []
          },
          "m": [
            []
          ],
          "e": "son"
        }

        """)
    }

    @Test func numbersAndStringsAreCopiedVerbatim() throws {
        let input = #"[12345678901234567890, 1e-7, -0.0, 1.50, 2E+10, "\u00e7\/\n", "ğüşİ 😀", "\ud83d\ude00"]"#
        #expect(try JSONFormatter.minify(input) == #"[12345678901234567890,1e-7,-0.0,1.50,2E+10,"\u00e7\/\n","ğüşİ 😀","\ud83d\ude00"]"#)
        let formatted = try JSONFormatter.format(input, indent: 4)
        #expect(formatted.hasPrefix("[\n    12345678901234567890,\n    1e-7,\n    -0.0,\n    1.50,"))
        #expect(formatted.contains(#"    "\u00e7\/\n","#))
    }

    @Test func formattingIsIdempotentAndScalarsWork() throws {
        let once = try JSONFormatter.format(" {\r\n\t\"a\" : [ true , false , null ] } ")
        #expect(try JSONFormatter.format(once) == once)
        #expect(try JSONFormatter.format("  \"tek\" ") == "\"tek\"\n")
        #expect(try JSONFormatter.format("{ }") == "{}\n")
        #expect(try JSONFormatter.minify(once) == #"{"a":[true,false,null]}"#)
    }

    @Test func deepNestingDoesNotRecurse() throws {
        let depth = 100_000
        let input = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        #expect(try JSONFormatter.minify(input) == input)
    }

    @Test(arguments: [
        ("[1, 2,]", 1, 7, "trailing commas are not allowed"),
        ("{\"a\": 1,\n }", 2, 2, "trailing commas are not allowed"),
        ("{a: 1}", 1, 2, "keys must be in double quotes"),
        ("{'a': 1}", 1, 2, "keys must be in double quotes"),
        ("{\"a\": [1, 2", 1, 12, "unexpected end of document"),
        ("{\"çğ\": \"açık", 1, 8, "unterminated string"),
        ("", 1, 1, "empty document"),
        ("[01]", 1, 2, "invalid number"),
        ("[1.]", 1, 2, "invalid number"),
        ("[.5]", 1, 2, "unexpected character \".\""),
        ("[NaN]", 1, 2, "unexpected character \"N\""),
        ("[tru]", 1, 2, "unexpected character \"t\""),
        ("{\"a\" 1}", 1, 6, "expected ':'"),
        ("[1 2]", 1, 4, "expected ',' or ']'"),
        ("{} []", 1, 4, "extra content after the value"),
        ("[\"a\tb\"]", 1, 4, "unescaped control character in string"),
        ("[\"\\x\"]", 1, 3, "invalid escape sequence"),
        ("[\"\\u12G4\"]", 1, 3, "invalid \\u escape"),
        ("// yorum\n{}", 1, 1, "unexpected character \"/\""),
        ("[\"ş\", ü]", 1, 7, "unexpected character \"ü\""),
    ])
    func rejectsInvalidJSON(input: String, line: Int, column: Int, message: String) {
        do {
            _ = try JSONFormatter.format(input)
            Issue.record("expected an error for \(input)")
        } catch let error as JSONFormatError {
            #expect(error.line == line)
            #expect(error.column == column)
            #expect(error.message == message)
            #expect(error.localizedDescription == "Invalid JSON (\(line):\(column)): \(message)")
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func errorOffsetIsUTF16() {
        let input = "{\"😀\": x}"
        #expect(throws: JSONFormatError(line: 1, column: 7, offset: 7, message: "unexpected character \"x\"")) {
            try JSONFormatter.format(input)
        }
    }

    @Test func languageFormatting() throws {
        #expect(CodeLanguage.json.canFormat)
        #expect(!CodeLanguage.yaml.canFormat)
        #expect(try CodeLanguage.json.format("[1]") == "[\n  1\n]\n")
        #expect(throws: JSONFormatError.self) { try CodeLanguage.swift.format("x") }
    }

    @Test func largeDocumentIsFast() throws {
        let item = #"{"ad": "Çağlar", "sayı": -12.5e3, "liste": [1, 2, 3], "ok": true, "x": null}"#
        let input = "[" + Array(repeating: item, count: 20_000).joined(separator: ",") + "]"
        let clock = ContinuousClock()
        var output = ""
        let elapsed = try clock.measure { output = try JSONFormatter.format(input) }
        #expect(output.count > input.count)
        #expect(elapsed < .seconds(2))
    }

    @Test func refusesExtremeNesting() throws {
        let ok = String(repeating: "[", count: JSONFormatter.maxDepth) + String(repeating: "]", count: JSONFormatter.maxDepth)
        #expect(throws: Never.self) { try JSONFormatter.format(ok) }
        let deep = "[" + ok + "]"
        let error = try #require(throws: JSONFormatError.self) { try JSONFormatter.format(deep) }
        #expect(error.offset == JSONFormatter.maxDepth)
        #expect(error.message.contains("too deep"))
    }
}
