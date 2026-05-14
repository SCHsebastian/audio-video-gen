import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Domain

struct ExportSheetView: View {
    @Bindable var vm: ExportViewModel
    @Bindable var localizer: BundleLocalizer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Text(localizer.string(.exportSheetTitle))
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 12)

            Form {
                Section(localizer.string(.exportAudioSourceSection)) {
                    Button(localizer.string(.exportAudioSourceChoose)) {
                        chooseAudioFile()
                    }
                    if let url = vm.audioURL {
                        Text(url.lastPathComponent)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Section(localizer.string(.exportVisualsSection)) {
                    Picker(localizer.string(.exportVisualsScene),
                           selection: $vm.scene) {
                        ForEach(SceneKind.allCases, id: \.self) { kind in
                            Text(sceneDisplayName(kind)).tag(kind)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker(localizer.string(.exportVisualsPalette),
                           selection: $vm.paletteName) {
                        ForEach(PaletteFactory.all, id: \.name) { palette in
                            Text(palette.name).tag(palette.name)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section(localizer.string(.exportOutputSection)) {
                    Picker(localizer.string(.exportOutputResolution),
                           selection: $vm.resolution) {
                        Text("1280 × 720").tag(RenderOptions.Resolution.hd720)
                        Text("1920 × 1080").tag(RenderOptions.Resolution.hd1080)
                        Text("3840 × 2160").tag(RenderOptions.Resolution.uhd4k)
                    }
                    .pickerStyle(.menu)

                    Picker(localizer.string(.exportOutputFps),
                           selection: $vm.frameRate) {
                        Text("30 fps").tag(RenderOptions.FrameRate.fps30)
                        Text("60 fps").tag(RenderOptions.FrameRate.fps60)
                    }
                    .pickerStyle(.menu)

                    Button(localizer.string(.exportOutputLocation)) {
                        chooseOutputLocation()
                    }
                    if let url = vm.outputURL {
                        Text(url.lastPathComponent)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button(localizer.string(.exportCancel)) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button(localizer.string(.exportStart)) {
                    vm.start()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(vm.audioURL == nil || vm.outputURL == nil)
            }
            .padding(.top, 12)
        }
        .padding(20)
        .frame(width: 480)
    }

    private func chooseAudioFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if let audioType = UTType("public.audio") {
            panel.allowedContentTypes = [audioType]
        }
        panel.allowedFileTypes = ["mp3", "wav", "m4a", "aac", "flac", "aiff", "caf"]
        if panel.runModal() == .OK, let url = panel.url {
            vm.audioURL = url
            if vm.outputURL == nil {
                let base = url.deletingPathExtension().lastPathComponent
                if let docs = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first {
                    vm.outputURL = docs.appendingPathComponent("\(base).mp4")
                }
            }
        }
    }

    private func chooseOutputLocation() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        let suggested: String
        if let url = vm.audioURL {
            suggested = url.deletingPathExtension().lastPathComponent + ".mp4"
        } else {
            suggested = "visualization.mp4"
        }
        panel.nameFieldStringValue = suggested
        if panel.runModal() == .OK, let url = panel.url {
            vm.outputURL = url
        }
    }

    private func sceneDisplayName(_ k: SceneKind) -> String {
        switch k {
        case .bars: return localizer.string(.sceneBars)
        case .scope: return localizer.string(.sceneScope)
        case .alchemy: return localizer.string(.sceneAlchemy)
        case .tunnel: return localizer.string(.sceneTunnel)
        case .lissajous: return localizer.string(.sceneLissajous)
        case .radial: return localizer.string(.sceneRadial)
        case .rings: return localizer.string(.sceneRings)
        case .synthwave: return localizer.string(.sceneSynthwave)
        case .spectrogram: return localizer.string(.sceneSpectrogram)
        case .milkdrop: return localizer.string(.sceneMilkdrop)
        case .kaleidoscope: return localizer.string(.sceneKaleidoscope)
        }
    }
}
