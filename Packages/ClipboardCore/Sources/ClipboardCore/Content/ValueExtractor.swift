import Foundation

public struct ValueExtractor: Sendable {
    public init() {}

    public func candidates(in source: String) -> [ValueCandidate] {
        var detected: [DetectedValue] = []
        detected += matches(
            pattern: #"(?<![0-9])(?:\+82[- ]?1[016789]|01[016789])[- ]?[0-9]{3,4}[- ]?[0-9]{4}(?![0-9])"#,
            kind: .phoneNumber,
            in: source
        )
        detected += matches(
            pattern: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
            kind: .emailAddress,
            in: source,
            options: [.caseInsensitive]
        )
        detected += matches(
            pattern: #"https?://[^\s<>\"']+"#,
            kind: .url,
            in: source,
            options: [.caseInsensitive]
        )

        let occupied = detected.map(\.range)
        detected += contextualMatches(
            pattern: #"(?<![0-9])[0-9]{4,8}(?![0-9])"#,
            kind: .oneTimeCode,
            cues: ["인증번호", "인증 번호", "인증코드", "인증 코드", "OTP", "일회용 코드", "일회용 비밀번호"],
            in: source,
            excluding: occupied
        )
        let accountMatches = contextualMatches(
            pattern: #"(?<![0-9])(?:[0-9]{2,6}(?:[- ][0-9]{2,6}){1,4}|[0-9]{10,16})(?![0-9])"#,
            kind: .accountNumber,
            cues: [
                "계좌", "입금", "국민은행", "KB국민은행", "신한은행", "우리은행", "하나은행", "농협은행", "NH농협은행",
                "기업은행", "IBK기업은행", "카카오뱅크", "토스뱅크",
            ],
            in: source,
            excluding: detected.map(\.range)
        )
        detected += accountMatches.filter { isPlausibleAccountCandidate($0, in: source) }

        return detected
            .sorted {
                if $0.range.location == $1.range.location {
                    return $0.kind.rawValue < $1.kind.rawValue
                }
                return $0.range.location < $1.range.location
            }
            .map { detectedValue in
                let original = detectedValue.original
                let digits = original.filter { $0.wholeNumberValue != nil }
                let digitsOnly: String? = switch detectedValue.kind {
                case .phoneNumber, .oneTimeCode, .accountNumber: digits
                case .emailAddress, .url: nil
                }
                let normalized: String? = switch detectedValue.kind {
                case .emailAddress: original.lowercased()
                case .url: original
                case .phoneNumber, .oneTimeCode, .accountNumber: digits
                }
                return ValueCandidate(
                    kind: detectedValue.kind,
                    original: original,
                    digitsOnly: digitsOnly,
                    normalized: normalized,
                    context: boundedContext(around: detectedValue.range, in: source),
                    bankName: nil
                )
            }
    }

    private func matches(
        pattern: String,
        kind: ValueKind,
        in source: String,
        options: NSRegularExpression.Options = []
    ) -> [DetectedValue] {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let fullRange = NSRange(source.startIndex ..< source.endIndex, in: source)
        return expression.matches(in: source, range: fullRange).compactMap { match in
            guard let range = Range(match.range, in: source) else { return nil }
            var original = String(source[range])
            if kind == .url {
                original = original.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?)]}"))
            }
            guard !original.isEmpty else { return nil }
            let adjustedRange = NSRange(range, in: source)
            return DetectedValue(kind: kind, original: original, range: adjustedRange)
        }
    }

    private func contextualMatches(
        pattern: String,
        kind: ValueKind,
        cues: [String],
        in source: String,
        excluding occupied: [NSRange]
    ) -> [DetectedValue] {
        matches(pattern: pattern, kind: kind, in: source).filter { candidate in
            guard !occupied.contains(where: { NSIntersectionRange($0, candidate.range).length > 0 }) else { return false }
            let context = nearbyContext(around: candidate.range, in: source)
            return cues.contains { context.range(of: $0, options: [.caseInsensitive]) != nil }
        }
    }

    private func nearbyContext(around range: NSRange, in source: String) -> String {
        guard let sourceRange = Range(range, in: source) else { return "" }
        let start = source.index(sourceRange.lowerBound, offsetBy: -24, limitedBy: source.startIndex) ?? source.startIndex
        let end = source.index(sourceRange.upperBound, offsetBy: 24, limitedBy: source.endIndex) ?? source.endIndex
        return String(source[start ..< end])
    }

    private func isPlausibleAccountCandidate(_ candidate: DetectedValue, in source: String) -> Bool {
        let digitCount = candidate.original.filter { $0.wholeNumberValue != nil }.count
        guard (8 ... 16).contains(digitCount) else { return false }

        let context = precedingContext(before: candidate.range, in: source)
        return context.range(of: #"주문\s*번호"#, options: .regularExpression) == nil
    }

    private func precedingContext(before range: NSRange, in source: String) -> String {
        guard let sourceRange = Range(range, in: source) else { return "" }
        let start = source.index(sourceRange.lowerBound, offsetBy: -24, limitedBy: source.startIndex) ?? source.startIndex
        return String(source[start ..< sourceRange.lowerBound])
    }

    private func boundedContext(around range: NSRange, in source: String) -> String {
        guard let sourceRange = Range(range, in: source) else { return "" }
        let start = source.index(sourceRange.lowerBound, offsetBy: -16, limitedBy: source.startIndex) ?? source.startIndex
        let provisionalEnd = source.index(sourceRange.upperBound, offsetBy: 16, limitedBy: source.endIndex) ?? source.endIndex
        let end = source.index(start, offsetBy: 48, limitedBy: provisionalEnd) ?? provisionalEnd
        return String(source[start ..< end])
    }
}

private struct DetectedValue {
    let kind: ValueKind
    let original: String
    let range: NSRange
}
