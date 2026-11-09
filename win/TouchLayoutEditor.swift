import SwiftUI

/// Arranging the on-screen controller, in landscape as in a program: drag a group to move it,
/// pinch it to resize it, and set the overall size, opacity and vibration. For all programs,
/// or for one program.
struct TouchLayoutEditor: View {
    /// nil: the layout for all programs.
    let programID: String?
    let programName: String?

    @State private var layout: TouchLayout
    /// For a program: whether it gets a layout of its own (else the one for all programs is edited).
    @State private var ownLayout: Bool
    @State private var panelOpen = true
    @Environment(\.dismiss) private var dismiss

    init(programID: String? = nil, programName: String? = nil) {
        self.programID = programID
        self.programName = programName
        let own = programID.map(TouchLayout.hasOwn) ?? false
        _ownLayout = State(initialValue: programID == nil || own)
        _layout = State(initialValue: TouchLayout.load(for: programID))
    }

    var body: some View {
        ZStack {
            // Something like a program's picture behind, to judge the opacity.
            LinearGradient(colors: [Color(white: 0.25), Color(red: 0.12, green: 0.18, blue: 0.3)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            TouchControllerRepresentable(layout: layout, editing: true) { layout = $0 }
                .ignoresSafeArea()

            if panelOpen {
                panel
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            } else {
                Button("Show Options", systemImage: "slider.horizontal.3") {
                    withAnimation { panelOpen = true }
                }
                .buttonStyle(.borderedProminent)
                .frame(maxHeight: .infinity, alignment: .center)
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onChange(of: ownLayout) { _, own in
            // Back to the shared layout; a program's own starts from what is shown.
            if !own { layout = TouchLayout.load(for: nil) }
        }
        .onAppear { OrientationLock.landscape(true) }
        .onDisappear { OrientationLock.landscape(false) }
    }

    private var panel: some View {
        VStack(spacing: 10) {
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Text(scopeTitle).font(.headline).lineLimit(1)
                Spacer()
                Button("Save") { save() }.bold()
            }

            Text("Drag a group of buttons to move it; pinch it to resize it.")
                .font(.caption).foregroundStyle(.secondary)

            if programID != nil {
                Picker("Layout", selection: $ownLayout) {
                    Text("All Programs").tag(false)
                    Text("This Program Only").tag(true)
                }
                .pickerStyle(.segmented)
            }

            LabeledContent("Size") {
                Slider(value: $layout.size, in: TouchLayout.sizes)
                    .frame(width: 180)
            }
            LabeledContent("Opacity") {
                Slider(value: $layout.opacity, in: TouchLayout.opacities)
                    .frame(width: 180)
            }
            Toggle("Vibrate on Press", isOn: $layout.haptics)

            HStack {
                Button("Reset", systemImage: "arrow.counterclockwise", role: .destructive) {
                    layout = TouchLayout()
                }
                Spacer()
                Button("Hide Options", systemImage: "chevron.down") {
                    withAnimation { panelOpen = false }
                }
            }
            .font(.subheadline)
        }
        .padding(14)
        .frame(width: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var scopeTitle: String {
        guard let programName else { return "On-Screen Controller" }
        return ownLayout ? programName : "All Programs"
    }

    private func save() {
        if let programID, ownLayout {
            TouchLayout.save(layout, for: programID)
        } else {
            TouchLayout.save(layout, for: nil)
            // Edited from a program with "All Programs": that program follows the shared layout again.
            if let programID { TouchLayout.removeOwn(programID) }
        }
        dismiss()
    }
}

struct TouchControllerRepresentable: UIViewRepresentable {
    var layout: TouchLayout
    /// Editing the layout instead of playing (TouchLayoutEditor).
    var editing = false
    var onLayoutChange: ((TouchLayout) -> Void)?

    func makeUIView(context: Context) -> TouchControllerView {
        let view = TouchControllerView(frame: .zero)
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ uiView: TouchControllerView, context: Context) {
        uiView.layout = layout
        uiView.isEditing = editing
        uiView.onLayoutChange = onLayoutChange
    }

    static func dismantleUIView(_ uiView: TouchControllerView, coordinator: ()) { uiView.releaseAll() }
}
