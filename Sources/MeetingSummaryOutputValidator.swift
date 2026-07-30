import Foundation

enum MeetingSummaryOutputValidationError: Error, Equatable, Sendable {
    case sourceQuoteMissing
    case sourceQuoteNotFound
    case ownerNotGrounded
    case dueDateNotGrounded
    case languageMismatch
}

struct MeetingSummaryOutputValidator: Sendable {
    func validate(
        _ draft: MeetingSummaryDraftContentV2,
        outputLanguage: String = "",
        against transcript: String
    ) throws {
        try validate(
            draft,
            outputLanguage: outputLanguage,
            sourceTexts: [transcript]
        )
    }

    func validate(
        _ draft: MeetingSummaryDraftContentV2,
        outputLanguage: String = "",
        against source: SummarySourceData
    ) throws {
        try validate(
            draft,
            outputLanguage: outputLanguage,
            sourceTexts: Self.sourceTexts(for: source)
        )
    }

    func validate(
        _ draft: MeetingSummaryDraftContentV2,
        outputLanguage: String = "",
        againstValidatedRecords records: [MeetingSummaryDraftContentV2]
    ) throws {
        try validate(
            draft,
            outputLanguage: outputLanguage,
            sourceTexts: records.flatMap(\.validatedSourceTexts)
        )
    }

    private func validate(
        _ draft: MeetingSummaryDraftContentV2,
        outputLanguage: String,
        sourceTexts: [String]
    ) throws {
        let sources = sourceTexts.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        try validate(
            sourceQuotes: draft.overview.sourceQuotes.map(Optional.some),
            sources: sources
        )
        for point in draft.keyPoints + draft.decisions + draft.openQuestions {
            try validate(sourceQuotes: [point.sourceQuote], sources: sources)
        }
        for action in draft.actionItems {
            try validate(sourceQuotes: [action.sourceQuote], sources: sources)
            guard let sourceQuote = action.sourceQuote else {
                throw MeetingSummaryOutputValidationError.sourceQuoteMissing
            }
            if let owner = nonempty(action.owner),
               !containsWhitespaceNormalized(owner, in: sourceQuote) {
                throw MeetingSummaryOutputValidationError.ownerNotGrounded
            }
            if let dueDate = nonempty(action.dueDate),
               !containsDateNormalized(dueDate, in: sourceQuote) {
                throw MeetingSummaryOutputValidationError.dueDateNotGrounded
            }
        }

        switch AIOutputLanguageValidator(outputLanguage: outputLanguage).validate(
            generatedProse: generatedProse(from: draft)
        ) {
        case .mismatch:
            throw MeetingSummaryOutputValidationError.languageMismatch
        case .accepted, .notRequested, .uncertain:
            break
        }
    }

    private func validate(
        sourceQuotes: [String?],
        sources: [String]
    ) throws {
        guard !sourceQuotes.isEmpty else {
            throw MeetingSummaryOutputValidationError.sourceQuoteMissing
        }
        for quote in sourceQuotes {
            guard let quote = nonempty(quote) else {
                throw MeetingSummaryOutputValidationError.sourceQuoteMissing
            }
            let membershipQuote = quote.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard sources.contains(where: { $0.range(of: membershipQuote, options: .literal) != nil }) else {
                throw MeetingSummaryOutputValidationError.sourceQuoteNotFound
            }
        }
    }

    private func generatedProse(
        from draft: MeetingSummaryDraftContentV2
    ) -> String {
        var prose = [draft.overview.text]
        prose.append(contentsOf: draft.keyPoints.map(\.text))
        prose.append(contentsOf: draft.decisions.map(\.text))
        prose.append(contentsOf: draft.actionItems.map(\.task))
        prose.append(contentsOf: draft.openQuestions.map(\.text))
        return prose.joined(separator: "\n")
    }

    private func containsWhitespaceNormalized(
        _ value: String,
        in sourceQuote: String
    ) -> Bool {
        normalizedQuote(sourceQuote).range(
            of: normalizedQuote(value),
            options: .literal
        ) != nil
    }

    private func containsDateNormalized(
        _ dueDate: String,
        in sourceQuote: String
    ) -> Bool {
        let normalizedDueDate = normalizedQuote(dueDate)
        let normalizedQuote = normalizedQuote(sourceQuote)
        if normalizedQuote.range(of: normalizedDueDate, options: .literal) != nil {
            return true
        }
        guard let dueDateValue = parseDate(normalizedDueDate) else {
            return false
        }
        return dateStrings(in: normalizedQuote).contains { candidate in
            parseDate(candidate) == dueDateValue
        }
    }

    private func dateStrings(in text: String) -> [String] {
        let patterns = [
            #"\b\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z)?\b"#,
            #"\b(?:January|February|March|April|May|June|July|August|September|October|November|December)\s+\d{1,2},?\s+\d{4}\b"#,
            #"\b(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)\.?\s+\d{1,2},?\s+\d{4}\b"#
        ]
        return patterns.flatMap { pattern in
            guard let expression = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            ) else {
                return [String]()
            }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            return expression.matches(in: text, range: range).compactMap {
                Range($0.range, in: text).map { String(text[$0]) }
            }
        }
    }

    private func parseDate(_ value: String) -> String? {
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: value) {
            return dayFormatter.string(from: date)
        }
        for format in [
            "yyyy-MM-dd",
            "MMMM d, yyyy",
            "MMMM d yyyy",
            "MMM d, yyyy",
            "MMM d yyyy"
        ] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return dayFormatter.string(from: date)
            }
        }
        return nil
    }

    private var dayFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizedQuote(_ value: String) -> String {
        value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func sourceTexts(for source: SummarySourceData) -> [String] {
        var texts = [source.transcript]
        guard let calendar = source.calendar else { return texts }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        texts.append(calendar.title)
        texts.append(formatter.string(from: calendar.start))
        texts.append(formatter.string(from: calendar.end))
        texts.append(contentsOf: calendar.attendees)
        return texts
    }
}
