import SwiftUI
import WidgetKit
import TruongScalerCore
import ScalerActivityUI
#if canImport(ActivityKit) && os(iOS)
import ActivityKit

/// Dynamic Island & Lock Screen Live Activity widget (`docs/07_BACKGROUND_AND_LIVE_ACTIVITY_SPEC.md` Section 2.2).
public struct UpscaleLiveActivityWidget: Widget {
    public init() {}

    public var body: some WidgetConfiguration {
        ActivityConfiguration(for: UpscaleActivityAttributes.self) { context in
            LockScreenBanner(context: context)
                .padding(14)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        CompactUpscaleSymbol(state: context.state)
                        Text(context.attributes.scaleFactorLabel)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    CompactUpscaleProgress(state: context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    UpscaleActivityDetails(state: context.state)
                }
            } compactLeading: {
                CompactUpscaleSymbol(state: context.state)
            } compactTrailing: {
                CompactUpscaleProgress(state: context.state)
            } minimal: {
                MinimalUpscaleProgress(state: context.state)
            }
        }
    }

    /// Lock screen / Notification Center banner.
    private struct LockScreenBanner: View {
        let context: ActivityViewContext<UpscaleActivityAttributes>

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    CompactUpscaleSymbol(state: context.state)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.sourceFileName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text("\(context.attributes.scaleFactorLabel) → \(context.attributes.targetResolutionLabel)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    CompactUpscaleProgress(state: context.state)
                }

                UpscaleActivityDetails(state: context.state)
            }
        }

    }

    // MARK: - Presentation helpers

    fileprivate static func symbolName(for phase: UpscaleActivityAttributes.ActivityPhase) -> String {
        switch phase {
        case .running: return "sparkles.rectangle.stack.fill"
        case .paused: return "pause.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .cancelled: return "xmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    fileprivate static func tint(for phase: UpscaleActivityAttributes.ActivityPhase) -> Color {
        switch phase {
        case .running: return .accentColor
        case .paused: return .yellow
        case .completed: return .green
        case .cancelled: return .orange
        case .failed: return .red
        }
    }

    fileprivate static func headline(for state: UpscaleActivityAttributes.ContentState) -> String {
        if state.isPaused, let statusMessage = state.statusMessage {
            return statusMessage
        }
        return state.stageTitle
    }

    fileprivate static func etaText(for state: UpscaleActivityAttributes.ContentState) -> String? {
        if state.isPaused { return nil }
        guard let seconds = state.estimatedSecondsRemaining else { return nil }
        if seconds <= 0 { return nil }
        return "~\(seconds)s remaining"
    }
}
#else
public struct UpscaleLiveActivityWidget: Widget {
    public init() {}
    public var body: some WidgetConfiguration {
        EmptyWidgetConfiguration()
    }
}
#endif
