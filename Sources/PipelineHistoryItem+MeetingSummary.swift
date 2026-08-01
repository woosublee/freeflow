import Foundation

extension PipelineHistoryItem {
    var meetingSummary: MeetingSummaryEnvelope? {
        guard let meetingSummaryJSON else { return nil }
        return try? JSONDecoder().decode(
            MeetingSummaryEnvelope.self,
            from: meetingSummaryJSON
        )
    }

    func withMeetingSummary(
        _ summary: MeetingSummaryEnvelope?
    ) -> PipelineHistoryItem {
        let encoded = summary.flatMap { try? JSONEncoder().encode($0) }
        return copying(
            meetingSummaryJSON: encoded,
            spokenLanguageCode: spokenLanguageCode,
            spokenLanguageResolution: spokenLanguageResolution,
            meetingSummaryAttempt: meetingSummaryAttempt,
            customTitle: customTitle,
            postProcessedTranscript: postProcessedTranscript
        )
    }

    func withMeetingSummaryAttempt(
        _ attempt: MeetingSummaryAttempt?
    ) -> PipelineHistoryItem {
        copying(
            meetingSummaryJSON: meetingSummaryJSON,
            spokenLanguageCode: spokenLanguageCode,
            spokenLanguageResolution: spokenLanguageResolution,
            meetingSummaryAttempt: attempt,
            customTitle: customTitle,
            postProcessedTranscript: postProcessedTranscript
        )
    }
}
