import SwiftUI
import AppKit
import Domain
import Application

struct ExportProgressChip: View {
    @Bindable var vm: ExportViewModel
    let localizer: Localizing

    var body: some View {
        Group {
            switch vm.state {
            case .some(.preparing):
                renderingChip(framesEncoded: 0, totalFrames: nil)
            case .some(.rendering(let frames, let total)):
                renderingChip(framesEncoded: frames, totalFrames: total)
            case .some(.finalising):
                finalizingChip
            case .some(.completed):
                completedChip
            case .some(.failed(let err)):
                failedChip(err)
            case .some(.cancelled), .none:
                EmptyView()
            }
        }
    }

    private func renderingChip(framesEncoded: Int, totalFrames: Int?) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(progressLabel(framesEncoded: framesEncoded, totalFrames: totalFrames))
                .font(.callout.weight(.medium))
                .foregroundStyle(.white)
            Button {
                vm.cancel()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain)
            .help(localizer.string(.exportCancel))
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var finalizingChip: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(localizer.string(.exportProgressFinalizing))
                .font(.callout.weight(.medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var completedChip: some View {
        Button {
            if let url = vm.lastCompletedURL {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(localizer.string(.exportProgressDoneReveal))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func failedChip(_ err: ExportError) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
            Text(localizer.string(.exportProgressFailed))
                .font(.callout.weight(.medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .help(errorDescription(err))
    }

    private func progressLabel(framesEncoded: Int, totalFrames: Int?) -> String {
        let prefix = localizer.string(.exportProgressInProgress)
        if let total = totalFrames, total > 0 {
            let pct = Int((Double(framesEncoded) / Double(total)) * 100.0)
            let fps = currentFps()
            if fps > 0 {
                let remainingFrames = max(0, total - framesEncoded)
                let secondsRemaining = max(0, Int((Double(remainingFrames) / Double(fps)).rounded()))
                return "\(prefix) · \(pct)% · \(secondsRemaining) s"
            }
            return "\(prefix) · \(pct)% · \(framesEncoded) / \(total)"
        }
        return "\(prefix) · \(framesEncoded)"
    }

    /// Encoded fps inferred from the picked frame rate. Used to translate
    /// remaining frames into a human-friendly "N s" estimate. We assume the
    /// hardware encoder runs at real-time-or-faster (typical on Apple silicon),
    /// so seconds-remaining = framesRemaining / fps is a usable upper bound.
    private func currentFps() -> Int {
        vm.frameRate.rawValue
    }

    private func errorDescription(_ err: ExportError) -> String {
        switch err {
        case .fileUnreadable(let url, let desc):
            return "\(url.lastPathComponent): \(desc)"
        case .unsupportedAudioFormat(let desc):
            return desc
        case .outputUnwritable(let url, let desc):
            return "\(url.lastPathComponent): \(desc)"
        case .encoderFailed(let desc):
            return desc
        case .metalUnavailable:
            return "Metal unavailable"
        }
    }
}
