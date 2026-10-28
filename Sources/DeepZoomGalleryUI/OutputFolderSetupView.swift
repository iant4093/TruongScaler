import SwiftUI
import UniformTypeIdentifiers

/// The destination is always chosen by the user; processing never silently saves into input.
public struct OutputFolderSetupView: View {
    @Bindable var viewModel: StudioViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var choosingFolder = false

    public init(viewModel: StudioViewModel) { self.viewModel = viewModel }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Keep your results", systemImage: "folder.badge.plus")
                        .font(.title2.weight(.semibold))
                    Text("Choose a folder in Files for your processed photos. Results are organized by date, with an original copy for before/after comparisons. The same original is stored only once.")
                    Text("Your input photos stay untouched. Choose an output folder separate from your input folder.")
                        .foregroundStyle(.secondary)
                }
                Section("Output folder") {
                    LabeledContent("Location", value: viewModel.outputLocationLabel)
                    if viewModel.isValidatingOutputFolder { ProgressView("Checking folder…") }
                    if let message = viewModel.savedOutputRecoveryMessage { Text(message).foregroundStyle(.secondary) }
                    Button(viewModel.outputFolderURL == nil ? "Choose output folder" : "Change output folder") { choosingFolder = true }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("chooseOutputFolder")
                    if viewModel.hasSavedOutputBookmark {
                        Button("Reconnect saved folder") { Task { await viewModel.reconnectOutputFolder() } }
                            .frame(minHeight: 44)
                    }
                }
            }
            .navigationTitle("Save processed photos")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(viewModel.outputFolderURL == nil ? "Not now" : "Done") { dismiss() }
                }
            }
            .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    Task { await viewModel.setOutputFolder(url: url) }
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(.accentColor)
    }
}

struct LibraryCollectionBar: View {
    @Binding var selection: LibraryCollection
    @Namespace private var highlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .subheadline) private var labelSize = 15

    private var buttons: some View {
        HStack(spacing: 4) {
            ForEach(LibraryCollection.allCases) { collection in
                Button {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.28)) { selection = collection }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: collection.symbol)
                        Text(collection.title)
                    }
                        .font(.system(size: min(labelSize, 24), weight: .semibold))
                        .padding(.horizontal, 22)
                        .frame(minHeight: 50)
                        .foregroundStyle(selection == collection ? Color.white : Color.white.opacity(0.65))
                        .background {
                            if selection == collection {
                                Capsule().fill(Color.white.opacity(0.15))
                                    .matchedGeometryEffect(id: "selected-collection", in: highlight)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == collection ? [.isSelected] : [])
                .accessibilityIdentifier("library-tab-" + collection.rawValue)
            }
        }
        .padding(7)
    }

    var body: some View {
        Group {
            #if os(iOS)
            if #available(iOS 26, *) {
                buttons.glassEffect(.regular, in: .capsule)
            } else {
                buttons.background(.ultraThinMaterial, in: Capsule())
            }
            #else
            buttons.background(.ultraThinMaterial, in: Capsule())
            #endif
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Photo collections")
    }
}
