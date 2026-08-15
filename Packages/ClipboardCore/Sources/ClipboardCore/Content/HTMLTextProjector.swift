import Foundation

public enum HTMLTextProjectorError: Error, Equatable {
    case invalidUTF8
}

public struct HTMLTextProjector: Sendable {
    public init() {}

    public func project(_ data: Data) throws -> String {
        guard let html = String(data: data, encoding: .utf8) else {
            throw HTMLTextProjectorError.invalidUTF8
        }

        var output = ""
        var cursor = html.startIndex
        var ignoredElement: String?

        while cursor < html.endIndex {
            if let ignoredName = ignoredElement {
                guard let closingEnd = closingTagEnd(for: ignoredName, from: cursor, in: html) else {
                    break
                }
                ignoredElement = nil
                cursor = closingEnd
                continue
            }

            guard html[cursor] == "<" else {
                let nextTag = html[cursor...].firstIndex(of: "<") ?? html.endIndex
                output.append(decodeEntities(String(html[cursor ..< nextTag])))
                cursor = nextTag
                continue
            }

            if html[cursor...].hasPrefix("<!--") {
                guard let commentEnd = html[cursor...].range(of: "-->")?.upperBound else { break }
                cursor = commentEnd
                continue
            }

            guard let tagEnd = tagEnd(from: cursor, in: html) else {
                output.append(decodeEntities(String(html[cursor...])))
                break
            }

            let rawTag = html[html.index(after: cursor) ..< tagEnd]
            let tag = parseTag(rawTag)
            if tag.name == "script" || tag.name == "style" {
                if !tag.isClosing, !tag.isSelfClosing {
                    ignoredElement = tag.name
                }
            } else if isBlockSeparator(tag.name) {
                appendSeparator(to: &output)
            }
            cursor = html.index(after: tagEnd)
        }

        return output.trimmingCharacters(in: .newlines)
    }

    private func closingTagEnd(for name: String, from start: String.Index, in html: String) -> String.Index? {
        var searchStart = start
        while let closingStart = html.range(
            of: "</\(name)",
            options: [.caseInsensitive],
            range: searchStart ..< html.endIndex
        )?.lowerBound {
            guard let end = tagEnd(from: closingStart, in: html) else { return nil }
            let rawTag = html[html.index(after: closingStart) ..< end]
            let tag = parseTag(rawTag)
            if tag.isClosing, tag.name == name {
                return html.index(after: end)
            }
            searchStart = html.index(after: closingStart)
        }
        return nil
    }

    private func tagEnd(from start: String.Index, in html: String) -> String.Index? {
        var cursor = html.index(after: start)
        var quote: Character?
        while cursor < html.endIndex {
            let character = html[cursor]
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                return cursor
            }
            cursor = html.index(after: cursor)
        }
        return nil
    }

    private func parseTag(_ rawTag: Substring) -> (name: String, isClosing: Bool, isSelfClosing: Bool) {
        let trimmed = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
        let isClosing = trimmed.hasPrefix("/")
        let nameStart = trimmed.index(trimmed.startIndex, offsetBy: isClosing ? 1 : 0)
        let remainder = trimmed[nameStart...]
        let nameEnd = remainder.firstIndex { $0.isWhitespace || $0 == "/" } ?? remainder.endIndex
        return (String(remainder[..<nameEnd]).lowercased(), isClosing, trimmed.hasSuffix("/"))
    }

    private func isBlockSeparator(_ name: String) -> Bool {
        ["address", "article", "aside", "blockquote", "br", "div", "footer", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "li", "main", "nav", "p", "pre", "section", "tr"].contains(name)
    }

    private func appendSeparator(to output: inout String) {
        guard !output.isEmpty, !output.hasSuffix("\n") else { return }
        output.append("\n")
    }

    private func decodeEntities(_ text: String) -> String {
        let maximumEntityLength = 10
        var result = ""
        var cursor = text.startIndex
        while cursor < text.endIndex {
            guard text[cursor] == "&" else {
                result.append(text[cursor])
                cursor = text.index(after: cursor)
                continue
            }

            let entityStart = text.index(after: cursor)
            var scan = entityStart
            var length = 0
            var semicolon: String.Index?
            while scan < text.endIndex, length <= maximumEntityLength {
                let character = text[scan]
                if character == ";" {
                    semicolon = scan
                    break
                }
                if character == "&" || character == "<" || character.isWhitespace {
                    break
                }
                length += 1
                scan = text.index(after: scan)
            }

            if let semicolon,
               length > 0,
               length <= maximumEntityLength,
               let decoded = decodeEntity(String(text[entityStart ..< semicolon]))
            {
                result.append(contentsOf: decoded)
                cursor = text.index(after: semicolon)
            } else {
                result.append(text[cursor])
                cursor = text.index(after: cursor)
            }
        }
        return result
    }

    private func decodeEntity(_ entity: String) -> String? {
        let named: [String: String] = [
            "amp": "&",
            "apos": "'",
            "bull": "•",
            "copy": "©",
            "euro": "€",
            "gt": ">",
            "hellip": "…",
            "ldquo": "“",
            "lt": "<",
            "lsquo": "‘",
            "mdash": "—",
            "nbsp": "\u{00A0}",
            "ndash": "–",
            "quot": "\"",
            "rdquo": "”",
            "reg": "®",
            "rsquo": "’",
            "trade": "™",
        ]
        if let decoded = named[entity] {
            return decoded
        }

        let scalarValue: UInt32?
        if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
            scalarValue = UInt32(entity.dropFirst(2), radix: 16)
        } else if entity.hasPrefix("#") {
            scalarValue = UInt32(entity.dropFirst())
        } else {
            scalarValue = nil
        }
        guard let scalarValue, let scalar = UnicodeScalar(scalarValue) else { return nil }
        return String(scalar)
    }
}
