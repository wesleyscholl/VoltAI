import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject var vm = BoltAIViewModel()
    @State private var selection = 0
    @State private var showErrorAlert = false
    @State private var hasShownErrorAlert = false

    var body: some View {
        TabView(selection: $selection) {
            homeView
                .tabItem {
                    Label("Home", systemImage: "bolt.circle")
                }
                .tag(0)

            indexView
                .tabItem {
                    Label("Index", systemImage: "tray.full")
                }
                .tag(1)

            settingsView
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(2)
        }
        .frame(minWidth: 780, minHeight: 520)
        .padding(.top, 12)
    .accentColor(Color(red: 0.11, green: 0.56, blue: 0.8))
    .background(LinearGradient(gradient: Gradient(colors: [Color(NSColor.windowBackgroundColor), Color(NSColor.systemGray)]), startPoint: .topLeading, endPoint: .bottomTrailing))
        .onChange(of: vm.lastError) { newErr in
            if newErr != nil && !hasShownErrorAlert {
                selection = 1 // switch to Index tab
                showErrorAlert = true
                hasShownErrorAlert = true
            } else if newErr == nil {
                hasShownErrorAlert = false
            }
        }
        .alert(isPresented: $showErrorAlert) {
            let msg = vm.lastError ?? "Index file missing"
            return Alert(title: Text("Index file missing"), message: Text(msg), dismissButton: .default(Text("Open Index"), action: { 
                selection = 1; 
                vm.lastError = nil;
                hasShownErrorAlert = false
            }))
        }
    }

    var homeView: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Add top padding inside each tab content to visually move the tab bar down
            Spacer().frame(height: 8)

            // Header section with improved spacing
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 16) {
                    LogoView()
                        .padding(.trailing, 4)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("BoltAI")
                            .font(.system(size: 34, weight: .bold))
                            // White text color for better contrast
                            .foregroundColor(.white)
                        Text("Fast local AI agent — Powered by Rust & TF-IDF")
                            .foregroundColor(.secondary)
                            .font(.system(size: 15))
                    }
                    Spacer()
                    Button(action: { selection = 1 }) {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                            Text("Index Documents")
                                .fontWeight(.semibold)
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 14)
                        .foregroundColor(.white)
                        .background(LinearGradient(gradient: Gradient(colors: [Color(red: 0.11, green: 0.56, blue: 0.8), Color(red: 0.18, green: 0.7, blue: 0.45)]), startPoint: .topLeading, endPoint: .bottomTrailing))
                        .cornerRadius(10)
                        .shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: 2)
                    }
                    .buttonStyle(.plain)
                    .scaleEffect(selection == 1 ? 0.98 : 1.0)
                    .animation(.spring(response: 0.2, dampingFraction: 0.8), value: selection)
                }

                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(NSColor.separatorColor).opacity(0.3))
                    .frame(height: 1)
            }
            .padding(.horizontal, 4)

            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
                .overlay(
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text("BoltAI Chat")
                                    .font(.headline)
                                Text("Ask questions about your indexed documents. Use the Index tab to add files.")
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                        }

                        Divider()

                        // Chat display
                        VStack(spacing: 0) {
                            ScrollViewReader { proxy in
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 12) {
                                        ForEach(vm.messages) { msg in
                                            MessageRow(msg: msg)
                                                .id(msg.id)
                                                .padding(.horizontal)
                                        }
                                        if vm.isLoading {
                                            ProgressView(vm.statusText)
                                                .padding(.horizontal)
                                        }
                                    }
                                    .padding(.vertical, 8)
                                }
                                .onChange(of: vm.messages.count) { _ in
                                    if let last = vm.messages.last {
                                        withAnimation(.easeOut(duration: 0.25)) {
                                            proxy.scrollTo(last.id, anchor: .bottom)
                                        }
                                    }
                                }
                            }
                            .frame(minHeight: 160, maxHeight: 320)

                            // Fancy input
                            HStack(spacing: 8) {
                                HStack {
                                    TextField(vm.isLoading ? "Processing..." : "Ask BoltAI...", text: $vm.input)
                                        .textFieldStyle(.plain)
                                        .padding(12)
                                        .background(Color(NSColor.textBackgroundColor))
                                        .cornerRadius(12)
                                        .onSubmit { vm.sendQuery() }
                                        .disabled(vm.isLoading)
                                        .font(.system(size: 14))
                                }
                                .padding(.leading, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color(NSColor.textBackgroundColor))
                                        .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
                                )

                                Button(action: { vm.sendQuery() }) {
                                    ZStack {
                                        if vm.isLoading {
                                            ProgressView().controlSize(.small)
                                        } else {
                                            Image(systemName: "paperplane.fill")
                                                .foregroundColor(.white)
                                                .font(.system(size: 16, weight: .semibold))
                                        }
                                    }
                                    .padding(14)
                                    .background(LinearGradient(gradient: Gradient(colors: [Color(red: 0.11, green: 0.56, blue: 0.8), Color(red: 0.18, green: 0.7, blue: 0.45)]), startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .cornerRadius(12)
                                    .shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: 2)
                                }
                                .buttonStyle(.plain)
                                .disabled(vm.isLoading)
                                .scaleEffect(vm.isLoading ? 0.95 : 1.0)
                                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: vm.isLoading)
                            }
                            .padding(12)
                        }
                    }
                    .padding()
                )
                .frame(maxWidth: .infinity, minHeight: 260)

            Spacer()
        }
        .padding(20)
    }

    var indexView: some View {
        HStack(spacing: 16) {
            Spacer().frame(height: 8)
            VStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(NSColor.controlBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color(red: 0.11, green: 0.56, blue: 0.8).opacity(0.3), lineWidth: 2)
                                .padding(1)
                        )
                        .shadow(color: Color.black.opacity(0.08), radius: 4, x: 0, y: 2)

                    VStack(spacing: 12) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 32, weight: .light))
                            .foregroundColor(Color(red: 0.11, green: 0.56, blue: 0.8))

                        Text("Drop documents here to index")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.primary)

                        Text("or click to select files")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                    .padding()

                    DropZone { paths in
                        Task { vm.index(paths: paths) }
                    }
                    .frame(height: 160)
                }
                .frame(height: 160)

                HStack(spacing: 12) {
                    Button(action: { Task { vm.index(paths: []) } }) {
                        Label("Rebuild Index", systemImage: "arrow.clockwise")
                            .frame(minWidth: 140)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 12)
                            .foregroundColor(Color(red: 0.11, green: 0.56, blue: 0.8))
                            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)

                    Button(action: {
                        // Open a folder chooser and index the selected folder
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.allowsMultipleSelection = false
                        panel.prompt = "Select"
                        if panel.runModal() == .OK, let url = panel.urls.first {
                            Task { vm.index(paths: [url]) }
                        }
                    }) {
                        Label("Index Folder…", systemImage: "folder")
                            .frame(minWidth: 140)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 12)
                            .foregroundColor(.white)
                            .background(LinearGradient(gradient: Gradient(colors: [Color(red: 0.11, green: 0.56, blue: 0.8), Color(red: 0.18, green: 0.7, blue: 0.45)]), startPoint: .topLeading, endPoint: .bottomTrailing))
                            .cornerRadius(8)
                            .shadow(color: Color.black.opacity(0.12), radius: 4, x: 0, y: 2)
                    }
                    .buttonStyle(.plain)
                }

                Divider()

                Text("Indexed Documents")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)

                if vm.indexedDocs.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "tray")
                            .font(.system(size: 24, weight: .light))
                            .foregroundColor(.secondary)
                        Text("No documents indexed yet")
                            .foregroundColor(.secondary)
                            .font(.system(size: 14))
                    }
                    .padding(.vertical, 20)
                } else {
                    List {
                        ForEach(vm.indexedDocs) { doc in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Image(systemName: "doc.text")
                                        .foregroundColor(Color(red: 0.11, green: 0.56, blue: 0.8))
                                        .font(.system(size: 14))
                                    Text(doc.path)
                                        .font(.system(size: 14, weight: .medium))
                                        .lineLimit(1)
                                }
                                Text(doc.text)
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal, 4)
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                }

                Spacer()
            }
            .padding(18)
            .frame(minWidth: 340)
        }
    }

    var settingsView: some View {
        ScrollView {
            VStack(spacing: 32) {
                Spacer().frame(height: 6)

                VStack(alignment: .leading, spacing: 20) {
                    Text("Settings")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(.white)

                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(NSColor.controlBackgroundColor))
                        .frame(height: 1)
                        .opacity(0.3)
                }
                .padding(.horizontal, 20)

                VStack(spacing: 24) {
                    SectionView(title: "General", icon: "gear") {
                        VStack(spacing: 16) {
                            Toggle("Enable background indexing", isOn: .constant(true))
                                .toggleStyle(SwitchToggleStyle(tint: Color(red: 0.11, green: 0.56, blue: 0.8)))

                            Picker("Theme", selection: .constant(0)) {
                                Text("System").tag(0)
                                Text("Light").tag(1)
                                Text("Dark").tag(2)
                            }
                            .pickerStyle(.menu)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    SectionView(title: "Advanced", icon: "wrench.and.screwdriver") {
                        Button(action: {
                            // reveal index JSON in Finder
                            let indexURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("../boltai_index.json")
                            NSWorkspace.shared.activateFileViewerSelecting([indexURL])
                        }) {
                            HStack {
                                Image(systemName: "folder")
                                Text("Open index file")
                                Spacer()
                                Image(systemName: "arrow.up.right")
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal, 12)
                            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)

                Spacer().frame(height: 20)
            }
        }
    }
}

struct MessageRow: View {
    var msg: ChatMessage
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if msg.role == "user" {
                ZStack {
                    Circle()
                        .fill(LinearGradient(gradient: Gradient(colors: [Color(red: 0.11, green: 0.56, blue: 0.8), Color(red: 0.18, green: 0.7, blue: 0.45)]), startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 36, height: 36)
                        .shadow(color: Color.black.opacity(0.15), radius: 3, x: 0, y: 1)
                    Image(systemName: "person.fill")
                        .foregroundColor(.white)
                        .font(.system(size: 16, weight: .medium))
                }
            } else {
                ZStack {
                    Circle()
                        .fill(LinearGradient(gradient: Gradient(colors: [Color(red: 0.18, green: 0.7, blue: 0.45), Color(red: 0.11, green: 0.56, blue: 0.8)]), startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 36, height: 36)
                        .shadow(color: Color.black.opacity(0.15), radius: 3, x: 0, y: 1)
                    Image(systemName: "bolt.fill")
                        .foregroundColor(.white)
                        .font(.system(size: 16, weight: .medium))
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(msg.role.capitalized)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fontWeight(.medium)
                // Make message text selectable so users can copy answers
                Text(msg.text)
                    .textSelection(.enabled)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(msg.role == "user" ?
                                  LinearGradient(gradient: Gradient(colors: [Color(red: 0.11, green: 0.56, blue: 0.8).opacity(0.1), Color(red: 0.18, green: 0.7, blue: 0.45).opacity(0.1)]), startPoint: .topLeading, endPoint: .bottomTrailing) :
                                  LinearGradient(gradient: Gradient(colors: [Color(NSColor.controlBackgroundColor), Color(NSColor.controlBackgroundColor)]), startPoint: .topLeading, endPoint: .bottomTrailing))
                            .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
                    )
                    .cornerRadius(16)
            }
            Spacer()
        }
        .padding(.horizontal, 4)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}

// Small lightning bolt logo used in the header
struct LogoView: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(gradient: Gradient(colors: [Color(red: 0.11, green: 0.56, blue: 0.8), Color(red: 0.18, green: 0.7, blue: 0.45)]), startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 56, height: 56)
                .shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: 2)

            Image(systemName: "bolt.fill")
                .foregroundColor(.white)
                .font(.system(size: 26, weight: .bold))
        }
    }
}

struct SectionView<Content: View>: View {
    let title: String
    let icon: String
    let content: Content

    init(title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundColor(Color(red: 0.11, green: 0.56, blue: 0.8))
                    .font(.system(size: 16, weight: .semibold))
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.primary)
            }

            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
                    )
            )
            .padding(.top, 4)
        }
    }
}
