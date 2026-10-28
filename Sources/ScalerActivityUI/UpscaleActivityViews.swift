import SwiftUI
import TruongScalerCore

/// Shared by the widget and actual UIKit layout tests. Compact regions use fixed small bounds;
/// filenames, long phase labels and ETAs belong in the expanded/Lock Screen presentation.
public enum UpscaleActivityStyle {
    public static func symbol(_ phase: UpscaleActivityAttributes.ActivityPhase) -> String {
        switch phase {
        case .running: return "arrow.up.right"
        case .paused: return "pause.fill"
        case .completed: return "checkmark"
        case .cancelled: return "xmark"
        case .failed: return "exclamationmark"
        }
    }

    public static func tint(_ phase: UpscaleActivityAttributes.ActivityPhase) -> Color {
        switch phase {
        case .running, .completed: return .green
        case .paused: return .yellow
        case .cancelled: return .orange
        case .failed: return .red
        }
    }
}

public struct CompactUpscaleSymbol: View {
    public let state: UpscaleActivityAttributes.ContentState
    public init(state: UpscaleActivityAttributes.ContentState) { self.state = state }
    public var body: some View {
        Image(systemName: UpscaleActivityStyle.symbol(state.phase))
            .resizable().scaledToFit()
            .frame(width: 14, height: 14)
            .foregroundStyle(UpscaleActivityStyle.tint(state.phase))
            .accessibilityLabel(state.stageTitle)
    }
}

public struct CompactUpscaleProgress: View {
    public let state: UpscaleActivityAttributes.ContentState
    public init(state: UpscaleActivityAttributes.ContentState) { self.state = state }
    public var body: some View {
        Text(state.compactProgressText)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .lineLimit(1).minimumScaleFactor(0.7)
            .frame(width: 34, height: 18, alignment: .trailing)
            .accessibilityLabel("\(max(0, state.completedTiles)) of \(max(0, state.totalTiles)) tiles saved")
    }
}

public struct MinimalUpscaleProgress: View {
    public let state: UpscaleActivityAttributes.ContentState
    public init(state: UpscaleActivityAttributes.ContentState) { self.state = state }
    public var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.25), lineWidth: 2)
            Circle().trim(from: 0, to: state.savedTileFraction)
                .stroke(UpscaleActivityStyle.tint(state.phase), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 16, height: 16)
        .accessibilityLabel("Upscale \(state.compactProgressText)")
    }
}

public struct UpscaleActivityDetails: View {
    public let state: UpscaleActivityAttributes.ContentState
    public init(state: UpscaleActivityAttributes.ContentState) { self.state = state }
    public var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if state.totalTiles > 0 {
                ProgressView(value: state.savedTileFraction)
                    .tint(UpscaleActivityStyle.tint(state.phase))
            }
            Text(state.isPaused ? (state.statusMessage ?? state.stageTitle) : state.stageTitle)
                .font(.caption).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                if state.totalTiles > 0 {
                    Text("\(min(max(0, state.completedTiles), state.totalTiles))/\(state.totalTiles) tiles saved")
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                Spacer(minLength: 2)
                if state.phase == .running, let start = state.startedAt {
                    // A system-rendered timer stays visibly alive without per-second activity pushes
                    // or pretending that another tile has committed.
                    Text(start, style: .timer).monospacedDigit()
                }
            }
            .font(.caption2).foregroundStyle(.secondary)
            if let remaining = state.remainingTimeText {
                Text(remaining).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}
