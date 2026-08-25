import Foundation

@main
struct RecordingOverlayNoticeSourceTests {
    static func main() throws {
        let source = try String(contentsOfFile: "Sources/RecordingOverlay.swift", encoding: .utf8)

        precondition(source.contains("private var degradedCaptureNoticeLifecycle = DegradedCombinedCaptureNoticeLifecycle()"))
        precondition(source.contains("func beginDegradedCombinedCaptureNoticeSession("))
        precondition(source.contains("func reconcileDegradedCombinedCaptureNotice("))
        precondition(source.contains("func recordingReminderFrameDidChange("))
        precondition(source.contains("func endDegradedCombinedCaptureNoticeSession("))
        precondition(source.contains("struct DegradedCaptureNoticeView: View"))

        let showRecordingBody = try functionBody(named: "showRecording", in: source)
        let showOverlayRange = try requiredRange(of: "self.showOverlayPanel(animatedResize: true)", in: showRecordingBody)
        let showFlushRange = try requiredRange(
            of: "self.markDegradedCaptureNoticePresentationReady(sessionID: noticeSessionID)",
            in: showRecordingBody
        )
        precondition(showRecordingBody.contains("noticeSessionID: UUID? = nil"))
        precondition(
            showOverlayRange.lowerBound < showFlushRange.lowerBound,
            "showRecording flushes a pending degraded notice only after the overlay is on screen"
        )

        let transitionBody = try functionBody(named: "transitionToRecording", in: source)
        let updateLayoutRange = try requiredRange(of: "self.updateOverlayLayout(animated: true)", in: transitionBody)
        let transitionFlushRange = try requiredRange(
            of: "self.markDegradedCaptureNoticePresentationReady(sessionID: noticeSessionID)",
            in: transitionBody
        )
        precondition(transitionBody.contains("noticeSessionID: UUID? = nil"))
        precondition(
            updateLayoutRange.lowerBound < transitionFlushRange.lowerBound,
            "transitionToRecording flushes a pending degraded notice only after layout is updated"
        )

        let reconcileBody = try functionBody(named: "reconcileDegradedCombinedCaptureNotice", in: source)
        precondition(reconcileBody.contains("degradedCaptureNoticeLifecycle.reconcile("))
        precondition(reconcileBody.contains("DegradedCombinedCaptureNoticeLifecycle.Request("))
        precondition(!reconcileBody.contains("guard let message else { return }"))
        precondition(!reconcileBody.contains("showError("), "persistent degraded notices never use the transient error fallback")

        let reminderFrameChangeBody = try functionBody(
            named: "recordingReminderFrameDidChange",
            in: source
        )
        precondition(reminderFrameChangeBody.contains(
            "degradedCaptureNoticeLifecycle.updateReminderFrame("
        ))
        precondition(reminderFrameChangeBody.contains(
            "recordingNoticeReminderFrame = reminderFrame"
        ))
        precondition(reminderFrameChangeBody.contains(
            "repositionVisibleRecordingNotice()"
        ))

        let baseAnchorBody = try functionBody(
            named: "baseNoticeAnchorFrame",
            in: source
        )
        precondition(baseAnchorBody.contains(
            "RecordingNoticeStackGeometry.overlayAnchorFrame("
        ))
        precondition(baseAnchorBody.contains("visibleFrame: visibleOverlayFrame"))
        precondition(baseAnchorBody.contains("targetFrame: overlayFrame"))

        let anchorBody = try functionBody(named: "degradedCaptureNoticeAnchor", in: source)
        precondition(anchorBody.contains("baseNoticeAnchorFrame(reminderFrame:"))
        precondition(anchorBody.contains("overlayWindow?.frame"))
        precondition(anchorBody.contains("overlayFrame"))
        precondition(!anchorBody.contains("showError("))

        let recordingNoticeAnchorBody = try functionBody(
            named: "recordingNoticeAnchorFrame",
            in: source
        )
        precondition(recordingNoticeAnchorBody.contains("visibleDegradedCaptureNoticeFrame"))
        precondition(recordingNoticeAnchorBody.contains("RecordingNoticeStackGeometry.lowestVisibleFrame"))
        let showErrorBody = try functionBody(named: "showError", in: source)
        precondition(showErrorBody.contains("dismissAll(endingDegradedCaptureSession: false)"))

        let presentBody = try functionBody(named: "showAnchoredDegradedCaptureNotice", in: source)
        precondition(presentBody.contains("panel.ignoresMouseEvents = false"))
        precondition(!presentBody.contains("asyncAfter"), "the persistent notice never auto-dismisses")
        precondition(presentBody.contains("DegradedCaptureNoticeView("))
        precondition(presentBody.contains("degradedCaptureNoticeWindow"))
        precondition(presentBody.contains(
            "RecordingNoticeStackGeometry.degradedCaptureNoticeWidth("
        ))
        precondition(presentBody.contains("anchorWidth: anchor.width"))
        precondition(!presentBody.contains("request.message.count"))
        precondition(!presentBody.contains("degradedCaptureNoticeToken"), "the lifecycle owns notice tokens")
        precondition(presentBody.contains(
            "degradedCaptureNoticePresentationToken = request.token"
        ))

        let dismissBody = try functionBody(
            named: "dismissDegradedCaptureNotice",
            in: source
        )
        precondition(dismissBody.contains(
            "degradedCaptureNoticePresentationToken == expectedToken"
        ))
        precondition(dismissBody.contains(
            "degradedCaptureNoticePresentationToken != expectedToken"
        ))
        precondition(dismissBody.contains("panel?.alphaValue = 1"))
        precondition(dismissBody.contains("repositionVisibleRecordingNotice()"))
        precondition(source.contains(
            "private var recordingNoticeReminderFrame: NSRect?"
        ))
        precondition(source.contains(
            "recordingNoticeReminderFrame = reminderFrame"
        ))

        let updateLayoutBody = try functionBody(
            named: "updateOverlayLayout",
            in: source
        )
        precondition(updateLayoutBody.contains(
            "repositionVisibleDegradedCaptureNotice()"
        ))

        let screenChangeBody = try functionBody(
            named: "handleScreenParametersChanged",
            in: source
        )
        precondition(screenChangeBody.contains("updateOverlayLayout(animated: false)"))
        precondition(!screenChangeBody.contains("repositionVisibleDegradedCaptureNotice()"))
        let repositionBody = try functionBody(
            named: "repositionVisibleDegradedCaptureNotice",
            in: source
        )
        precondition(repositionBody.contains("degradedCaptureNoticeLifecycle.visibleRequest"))
        precondition(repositionBody.contains("degradedCaptureNoticeAnchor("))
        precondition(repositionBody.contains("showAnchoredDegradedCaptureNotice("))

        let transcribingBody = try functionBody(named: "setTranscribingPhase", in: source)
        precondition(
            transcribingBody.contains("endDegradedCombinedCaptureNoticeSessionNow()"),
            "the degraded notice ends as soon as recording leaves the active phase"
        )
        let dismissAllBody = try functionBody(named: "dismissAll", in: source)
        precondition(dismissAllBody.contains("endingDegradedCaptureSession: Bool = true"))
        precondition(dismissAllBody.contains("if endingDegradedCaptureSession"))
        precondition(dismissAllBody.contains("endDegradedCombinedCaptureNoticeSessionNow()"))
        precondition(dismissAllBody.contains("degradedCaptureNoticeWindow?.orderOut(nil)"))

        let viewBody = try typeBody(named: "DegradedCaptureNoticeView", in: source)
        precondition(viewBody.contains("DegradedCaptureNoticeHoverCatcher"))
        precondition(viewBody.contains("Button(action: onDismiss)"))
        precondition(
            !viewBody.contains("if isHovering"),
            "hovering must not insert a new control and compress the message"
        )
        precondition(viewBody.contains(".opacity(isHovering ? 1 : 0)"))
        precondition(viewBody.contains(".allowsHitTesting(isHovering)"))
        precondition(
            viewBody.contains(".padding(.trailing, 28)"),
            "the message keeps a fixed trailing slot for the dismiss control"
        )
        precondition(!viewBody.contains("onContinue"))
        precondition(!viewBody.contains("onStop"))
        precondition(!viewBody.contains("stop.fill"))
        precondition(!viewBody.contains("Continue"))
        let hoverBody = try typeBody(named: "DegradedCaptureNoticeHoverCatcher", in: source)
        precondition(hoverBody.contains("NSTrackingArea("))

        precondition(source.contains("private var noticeWindow: NSPanel?"))
        precondition(source.contains("private var degradedCaptureNoticeWindow: NSPanel?"))
        precondition(source.contains(
            "private var degradedCaptureNoticePresentationToken: UUID?"
        ))
        precondition(!source.contains("private var degradedCaptureNoticeToken: UUID?"))

        print("RecordingOverlayNoticeSourceTests passed")
    }

    private static func functionBody(named name: String, in source: String) throws -> String {
        try body(startingWith: "func \(name)(", in: source)
    }

    private static func typeBody(named name: String, in source: String) throws -> String {
        try body(startingWith: "struct \(name)", in: source)
    }

    private static func body(startingWith signature: String, in source: String) throws -> String {
        guard let signatureRange = source.range(of: signature),
              let openBrace = source[signatureRange.upperBound...].firstIndex(of: "{") else {
            throw TestFailure("missing body starting with \(signature)")
        }

        var depth = 0
        var index = openBrace
        while index < source.endIndex {
            switch source[index] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(source[signatureRange.lowerBound...index])
                }
            default:
                break
            }
            index = source.index(after: index)
        }
        throw TestFailure("unterminated body starting with \(signature)")
    }

    private static func requiredRange(of needle: String, in source: String) throws -> Range<String.Index> {
        guard let range = source.range(of: needle) else {
            throw TestFailure("missing text: \(needle)")
        }
        return range
    }

    private struct TestFailure: Error, CustomStringConvertible {
        let description: String

        init(_ description: String) {
            self.description = description
        }
    }
}
