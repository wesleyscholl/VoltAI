import SwiftUI

struct ContentView: View {
    @StateObject private var vm = BoltAIViewModel()

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading) {
                HStack {
                    Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                        .resizable()
                        .frame(width: 28, height: 28)
                    Text("BoltAI")
                        .font(.largeTitle.bold())
                    Spacer()
                    if vm.isIndexing {
                        Button(action: { vm.cancelIndexing() }) {
                            Text("Cancel")
                        }
                        .keyboardShortcut(.cancelAction)
                    }
                }
                .padding()

                Divider()

                VStack {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(vm.messages) { m in
                                MessageRow(message: m)
                            }
                        }
                        .padding()
                    }

                    HStack {
                        TextField("Ask BoltAI...", text: $vm.input)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { vm.sendQuery() }
                        Button("Send") { vm.sendQuery() }
                            .keyboardShortcut(.defaultAction)
                    }
                    .padding()
                }
            }
        } content: {
            VStack {
                HStack {
                    Text("Files & Index")
                        .font(.headline)
                    Spacer()
                }
                .padding()

                DropZone { urls in
                    vm.index(paths: urls)
                }
                .frame(height: 220)
                .padding()

                if vm.isIndexing {
                    ProgressView(value: vm.progress)
                        .progressViewStyle(LinearProgressViewStyle())
                        .padding([.leading, .trailing])
                    Text(vm.progressMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding([.leading, .bottom])
                }

                List(vm.indexedDocs) { doc in
                    VStack(alignment: .leading) {
                        Text(doc.id).font(.subheadline.bold())
                        Text(doc.path).font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            .padding()
        } detail: {
            VStack(alignment: .leading) {
                Text("Inspector")
                    .font(.title2)
                    .padding()
                if let sel = vm.selectedDoc {
                    Text(sel.path)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding([.leading, .trailing])
                    ScrollView {
                        Text(sel.text)
                            .padding()
                    }
                } else {
                    Text("Select a document to view details.")
                        .foregroundColor(.secondary)
                        .padding()
                }
            }
        }
    }
}

struct MessageRow: View {
    let message: ChatMessage
    var body: some View {
        HStack(alignment: .top) {
            Text(message.role.uppercased())
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(message.text)
                .padding(10)
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(8)
            Spacer()
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
