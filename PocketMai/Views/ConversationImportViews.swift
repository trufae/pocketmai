import SwiftUI

struct ConversationCollectionImportView: View {
  private enum DestinationMode: String, CaseIterable, Identifiable {
    case newFolder
    case existingFolder

    var id: String { rawValue }

    var title: String {
      switch self {
      case .newFolder: "New Folder"
      case .existingFolder: "Existing Folder"
      }
    }
  }

  @EnvironmentObject private var store: AppStore

  let file: PendingConversationImportFile
  let onFinish: () -> Void

  @State private var preview: ConversationCollectionImportPreview?
  @State private var destinationMode = DestinationMode.newFolder
  @State private var newFolderName = "Imported Conversations"
  @State private var existingFolderID = ConversationFolder.defaultID
  @State private var isImporting = false
  @State private var toast: String?
  @State private var errorMessage: String?

  var body: some View {
    NavigationStack {
      Form {
        if let preview {
          contentsSection(preview)
          destinationSection
          Section {
            Button {
              importConversations(preview)
            } label: {
              if isImporting {
                HStack(spacing: 10) {
                  ProgressView()
                  Text("Importing...")
                }
              } else {
                Label(importButtonTitle(preview), systemImage: "square.and.arrow.down")
              }
            }
            .disabled(isImporting || !canImport)
          }
        } else if let errorMessage {
          Section {
            Label(errorMessage, systemImage: "exclamationmark.triangle")
              .foregroundStyle(.red)
          }
        } else {
          Section {
            HStack(spacing: 10) {
              ProgressView()
              Text("Reading \(file.filename)...")
            }
          }
        }

        if let errorMessage, preview != nil {
          Section {
            Label(errorMessage, systemImage: "exclamationmark.triangle")
              .foregroundStyle(.red)
          }
        }
      }
      .navigationTitle("Import Conversations")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            onFinish()
          }
        }
      }
    }
    .task(id: file.id) {
      preparePreview()
    }
    .settingsToast($toast, style: .success)
  }

  private func contentsSection(_ preview: ConversationCollectionImportPreview) -> some View {
    Section {
      infoRow("File", preview.file.filename)
      infoRow("PocketMai", preview.envelope.pocketMaiVersion)
      infoRow("Conversations", "\(preview.conversations.count)")
      ForEach(Array(preview.conversations.indices.prefix(8)), id: \.self) { index in
        let conversation = preview.conversations[index]
        Label(conversation.displayTitle, systemImage: "bubble.left")
          .lineLimit(1)
      }
      if preview.conversations.count > 8 {
        Text("and \(preview.conversations.count - 8) more...")
          .foregroundStyle(.secondary)
      }
    } header: {
      Text("Contents")
    }
  }

  private var destinationSection: some View {
    Section {
      Picker("Destination", selection: $destinationMode) {
        ForEach(DestinationMode.allCases) { mode in
          Text(mode.title).tag(mode)
        }
      }
      .pickerStyle(.segmented)

      switch destinationMode {
      case .newFolder:
        TextField("Folder name", text: $newFolderName)
          .textInputAutocapitalization(.words)
      case .existingFolder:
        Picker("Folder", selection: $existingFolderID) {
          ForEach(availableFolders) { folder in
            Label(folder.displayName, systemImage: folder.systemImage)
              .tag(folder.id)
          }
        }
      }
    } header: {
      Text("Import Into")
    } footer: {
      Text("Every conversation in the file will be placed in this folder.")
    }
  }

  private var availableFolders: [ConversationFolder] {
    store.conversationFolders.filter {
      $0.id != ConversationFolder.archivedID && store.canUseConversationFolder($0.id)
    }
  }

  private var canImport: Bool {
    switch destinationMode {
    case .newFolder:
      !newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case .existingFolder:
      availableFolders.contains { $0.id == existingFolderID }
    }
  }

  private func preparePreview() {
    do {
      let preview = try store.previewConversationCollectionImport(file)
      self.preview = preview
      newFolderName = store.suggestedConversationImportFolderName(
        conversationCount: preview.conversations.count)
      if availableFolders.contains(where: { $0.id == store.selectedConversationFolderID }) {
        existingFolderID = store.selectedConversationFolderID
      } else {
        existingFolderID = availableFolders.first?.id ?? ConversationFolder.defaultID
      }
      errorMessage = nil
    } catch {
      preview = nil
      errorMessage = error.localizedDescription
    }
  }

  private func importConversations(_ preview: ConversationCollectionImportPreview) {
    guard !isImporting else { return }
    isImporting = true
    errorMessage = nil
    let destination: ConversationCollectionImportDestination =
      switch destinationMode {
      case .newFolder:
        .newFolder(name: newFolderName)
      case .existingFolder:
        .existingFolder(id: existingFolderID)
      }
    Task { @MainActor in
      do {
        let count = try await store.importConversationCollection(
          preview, destination: destination)
        withAnimation(.snappy) {
          toast = "Imported \(count) conversation\(count == 1 ? "" : "s")."
        }
        try? await Task.sleep(for: .milliseconds(900))
        onFinish()
      } catch {
        errorMessage = error.localizedDescription
        isImporting = false
      }
    }
  }

  private func importButtonTitle(_ preview: ConversationCollectionImportPreview) -> String {
    let count = preview.conversations.count
    return "Import \(count) Conversation\(count == 1 ? "" : "s")"
  }

  private func infoRow(_ title: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title)
      Spacer(minLength: 12)
      Text(value)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.trailing)
    }
  }
}
