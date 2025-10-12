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
        VStack(alignment: .leading, spacing: 16) {
            // Add top padding inside each tab content to visually move the tab bar down
            Spacer().frame(height: 8)
            HStack(alignment: .center) {
                LogoView()
                    .padding(.trailing, 8)
                VStack(alignment: .leading, spacing: 6) {
                    Text("BoltAI")
                        .font(.system(size: 34, weight: .bold))
                    Text("Fast local AI agent — TF‑IDF powered")
                        .foregroundColor(.secondary)
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
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

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
                                        .padding(10)
                                        .background(Color(NSColor.textBackgroundColor))
                                        .cornerRadius(10)
                                        .onSubmit { vm.sendQuery() }
                                        .disabled(vm.isLoading)
                                }
                                .padding(.leading, 6)

                                Button(action: { vm.sendQuery() }) {
                                    ZStack {
                                        if vm.isLoading {
                                            ProgressView().controlSize(.small)
                                        } else {
                                            Image(systemName: "paperplane.fill")
                                                .foregroundColor(.white)
                                        }
                                    }
                                    .padding(12)
                                    .background(LinearGradient(gradient: Gradient(colors: [Color(red: 0.11, green: 0.56, blue: 0.8), Color(red: 0.18, green: 0.7, blue: 0.45)]), startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .cornerRadius(10)
                                }
                                .buttonStyle(.plain)
                                .disabled(vm.isLoading)
                            }
                            .padding(10)
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
                DropZone { paths in
                    Task { vm.index(paths: paths) }
                }
                .frame(height: 160)

                HStack(spacing: 12) {
                    Button(action: { Task { vm.index(paths: []) } }) {
                        Label("Rebuild Index", systemImage: "arrow.clockwise")
                            .frame(minWidth: 140)
                    }
                    .buttonStyle(.bordered)

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
                    }
                    .buttonStyle(.borderedProminent)
                }

                Divider()

                Text("Indexed Documents")
                    .font(.headline)

                if vm.indexedDocs.isEmpty {
                    Text("No documents indexed yet")
                        .foregroundColor(.secondary)
                } else {
                    List {
                        ForEach(vm.indexedDocs) { doc in
                            VStack(alignment: .leading) {
                                Text(doc.path)
                                    .font(.subheadline).bold()
                                Text(doc.text)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 6)
                        }
                    }
                    .listStyle(.inset)
                }

                Spacer()
            }
            .padding(18)
            .frame(minWidth: 340)
        }
    }

    var settingsView: some View {
        Form {
            Spacer().frame(height: 6)
            Section(header: Text("General")) {
                Toggle("Enable background indexing", isOn: .constant(true))
                Picker("Theme", selection: .constant(0)) {
                    Text("System").tag(0)
                    Text("Light").tag(1)
                    Text("Dark").tag(2)
                }
            }

            Section(header: Text("Advanced")) {
                Button("Open index file") {
                    // reveal index JSON in Finder
                    let indexURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("boltai_index.json")
                    NSWorkspace.shared.activateFileViewerSelecting([indexURL])
                }
            }
        }
        .padding(12)
    }
}

struct MessageRow: View {
    var msg: ChatMessage
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if msg.role == "user" {
                Circle().fill(Color.blue).frame(width: 40, height: 40)
            } else {
                Circle().fill(Color.green).frame(width: 40, height: 40)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(msg.role.capitalized)
                    .font(.caption)
                    .foregroundColor(.secondary)
                // Make message text selectable so users can copy answers
                Text(msg.text)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(10)
            }
        }
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
