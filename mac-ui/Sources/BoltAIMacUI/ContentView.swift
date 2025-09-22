import SwiftUI

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: String
    let text: String
}

struct ContentView: View {
    @State private var messages: [ChatMessage] = [ChatMessage(role: "system", text: "BoltAI local agent ready." )]
    @State private var input: String = ""
    @State private var isIndexing: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading) {
                Text("BoltAI — Local")
                    .font(.title2)
                    .padding(.leading)

                Divider()

                ScrollViewReader { sr in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(messages) { m in
                                HStack(alignment: .top) {
                                    Text(m.role.uppercased())
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .frame(width: 80, alignment: .leading)
                                    Text(m.text)
                                        .padding(8)
                                        .background(Color(NSColor.windowBackgroundColor))
                                        .cornerRadius(6)
                                    Spacer()
                                }
                            }
                        }
                        .padding()
                    }
                    .onChange(of: messages.count) { _ in
                        if let last = messages.last {
                            sr.scrollTo(last.id)
                        }
                    }
                }

                HStack {
                    TextField("Ask BoltAI...", text: $input)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .onSubmit { sendQuery() }
                    Button("Send") { sendQuery() }
                        .keyboardShortcut(.defaultAction)
                }
                .padding()
            }
            .frame(minWidth: 420)

            Divider()

            VStack(alignment: .leading) {
                Text("Files")
                    .font(.headline)
                    .padding([.top, .leading])

                DropZone { paths in
                    // index dropped files/folders
                    indexPaths(paths)
                }
                .frame(height: 220)
                .padding()

                Spacer()
            }
            .frame(width: 300)
        }
    }

    func sendQuery() {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        messages.append(ChatMessage(role: "user", text: q))
        input = ""

        DispatchQueue.global(qos: .userInitiated).async {
            let res = BoltAICaller.query(index: URL(fileURLWithPath: "boltai_index.json"), q: q, k: 5)
            DispatchQueue.main.async {
                messages.append(ChatMessage(role: "assistant", text: res))
            }
        }
    }

    func indexPaths(_ paths: [URL]) {
        isIndexing = true
        messages.append(ChatMessage(role: "system", text: "Indexing \(paths.count) paths..."))

        DispatchQueue.global(qos: .userInitiated).async {
            for p in paths {
                let _ = BoltAICaller.index(dir: p, out: URL(fileURLWithPath: "boltai_index.json"))
            }
            DispatchQueue.main.async {
                isIndexing = false
                messages.append(ChatMessage(role: "system", text: "Indexing complete."))
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
