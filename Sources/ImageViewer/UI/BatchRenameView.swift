import SwiftUI

/// The preview is a snapshot of exactly the files selected when the sheet opened.
struct BatchRenameView: View {
  @ObservedObject var store: AppStore
  @Environment(\.dismiss) private var dismiss
  private let assets: [ImageAsset]
  private let urls: [URL]
  @State private var options = BatchRenameOptions()
  @State private var startNumberText = "1"
  @State private var numberStepText = "1"
  @State private var classifications: BatchRenameClassifications?
  @State private var plan: BatchRenamePlan?
  @State private var previewRequest: PreviewRequest?
  @State private var errorMessage: String?

  init(store: AppStore) {
    self.store = store
    assets = store.batchAssets
    urls = assets.map(\.url)
  }

  private var numbersAreValid: Bool {
    options.nameMode == .classification || !options.addsNumber || ((Int(startNumberText).map { $0 >= 0 } ?? false)
      && (Int(numberStepText).map { $0 >= 1 } ?? false))
  }

  private struct PreviewRequest: Hashable, Sendable {
    let options: BatchRenameOptions
    let classifications: BatchRenameClassifications?
  }

  private var currentRequest: PreviewRequest {
    PreviewRequest(options: options, classifications: classifications)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Label("이름 일괄 변경", systemImage: "character.cursor.ibeam")
          .font(.title2.bold())
        Spacer()
        Text(L10n.format("%d개 선택", urls.count)).foregroundStyle(.secondary)
      }

      Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
        GridRow {
          Text("이름 규칙")
          Picker("이름 규칙", selection: $options.nameMode) {
            Text("현재 이름 유지").tag(BatchRenameOptions.NameMode.keep)
            Text("새 이름 사용").tag(BatchRenameOptions.NameMode.replace)
            Text("문구 찾아 바꾸기").tag(BatchRenameOptions.NameMode.replaceText)
            Text(BatchRenameL10n.text("classification.mode")).tag(BatchRenameOptions.NameMode.classification)
          }.labelsHidden()
        }
        if options.nameMode == .classification {
          GridRow {
            Text(BatchRenameL10n.text("classification.label"))
            Picker(BatchRenameL10n.text("classification.label"), selection: $options.classificationSlot) {
              Text(BatchRenameL10n.text("classification.choose")).tag(Optional<PhotoMarkSlot>.none)
              ForEach(PhotoMarkSlot.allCases, id: \.self) { slot in
                Text(classificationTitle(slot)).tag(Optional(slot))
              }
            }
            .labelsHidden()
            .disabled(classifications == nil)
          }
        } else if options.nameMode == .replace {
          GridRow {
            Text("새 이름")
            TextField("확장자를 제외한 이름", text: $options.newName)
          }
        } else if options.nameMode == .replaceText {
          GridRow {
            Text("찾을 문구")
            TextField("찾을 문구", text: $options.searchText)
          }
          GridRow {
            Text("바꿀 문구")
            TextField("바꿀 문구", text: $options.replacementText)
          }
        }
        if options.nameMode != .classification {
          GridRow {
            Text("앞에 붙일 문구")
            TextField("예: 여행_", text: $options.prefix)
          }
          GridRow {
            Text("뒤에 붙일 문구")
            TextField("예: _보정", text: $options.suffix)
          }
          GridRow {
            Text("일련번호")
            Toggle("이름 뒤에 번호 붙이기", isOn: $options.addsNumber)
          }
          if options.addsNumber {
            GridRow {
              Text("번호 설정")
              HStack(spacing: 12) {
                numberField("시작 번호", text: $startNumberText)
                numberField("증가 간격", text: $numberStepText)
                Picker("자릿수", selection: $options.numberDigits) {
                  ForEach(1...20, id: \.self) { count in Text("\(count)").tag(count) }
                }
                .frame(width: 110)
                numberField("구분자", text: $options.numberSeparator)
              }
            }
          }
        }
        GridRow {
          Text("확장자")
          HStack {
            Picker("확장자", selection: $options.extensionMode) {
              Text("유지").tag(BatchRenameOptions.ExtensionMode.keep)
              Text("소문자").tag(BatchRenameOptions.ExtensionMode.lowercase)
              Text("대문자").tag(BatchRenameOptions.ExtensionMode.uppercase)
              Text("직접 지정").tag(BatchRenameOptions.ExtensionMode.custom)
            }.labelsHidden()
            if options.extensionMode == .custom {
              TextField("예: jpeg", text: $options.customExtension).frame(width: 130)
            }
          }
        }
      }
      .textFieldStyle(.roundedBorder)
      .disabled(store.isRenaming)

      Text(BatchRenameL10n.format("numbering.help", BatchActionsL10n.text("export.menu")))
        .font(.caption).foregroundStyle(.secondary)
      if options.nameMode == .classification {
        Text(BatchRenameL10n.text("classification.help"))
          .font(.caption).foregroundStyle(.secondary)
      }
      if !numbersAreValid {
        Text("시작 번호는 0 이상, 증가 값은 1 이상, 자릿수는 1~20으로 입력해 주세요.")
          .font(.caption).foregroundStyle(.red)
      }

      Divider()
      HStack {
        Text("변경 미리보기").font(.headline)
        Spacer()
        if let plan, previewRequest == currentRequest {
          Text(L10n.format("%d개 변경", plan.changedCount))
            .foregroundStyle(.secondary)
        } else {
          ProgressView().controlSize(.small)
        }
      }
      if let plan {
        if let issue = plan.issue {
          Text(issue).font(.caption).foregroundStyle(.red)
        }
        if options.nameMode == .classification, plan.issue == nil {
          Text(BatchRenameL10n.format("classification.scope", plan.entries.count, urls.count))
            .font(.caption).foregroundStyle(.secondary)
        }
        Table(plan.entries) {
          TableColumn("현재 이름") { entry in
            Text(entry.sourceURL.lastPathComponent)
              .lineLimit(1).truncationMode(.middle).help(entry.sourceURL.path)
          }
          TableColumn("변경할 이름") { entry in
            VStack(alignment: .leading, spacing: 2) {
              Text(entry.destinationURL.lastPathComponent)
                .foregroundStyle(entry.issue == nil ? Color.primary : Color.red)
                .lineLimit(1).truncationMode(.middle)
              if let issue = entry.issue {
                Text(issue).font(.caption).foregroundStyle(.red).lineLimit(2)
              }
            }
            .help(entry.issue ?? entry.destinationURL.path)
          }
        }
        .opacity(previewRequest == currentRequest ? 1 : 0.45)
      } else {
        Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      HStack {
        Text("적용하면 선택한 원본 파일의 이름이 변경됩니다.")
          .font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button("취소", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction).disabled(store.isRenaming)
        Button {
          apply()
        } label: {
          if store.isRenaming { ProgressView().controlSize(.small) }
          else { Text("이름 변경 적용") }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(store.isRenaming || !numbersAreValid || previewRequest != currentRequest || plan?.canApply != true)
      }
    }
    .padding(20)
    .frame(width: 780, height: 710)
    .interactiveDismissDisabled(store.isRenaming)
    .onChange(of: startNumberText) { _, text in
      if let number = Int(text) { options.startNumber = number }
    }
    .onChange(of: numberStepText) { _, text in
      if let number = Int(text) { options.numberStep = number }
    }
    .task {
      await store.photoMarks.waitUntilReady()
      guard !Task.isCancelled, store.photoMarks.isReady else { return }
      classifications = BatchRenameClassifications(
        labels: Dictionary(uniqueKeysWithValues: PhotoMarkSlot.allCases.map { ($0, store.photoMarks.label(for: $0)) }),
        marksByURL: Dictionary(assets.map { ($0.url, store.photoMarks.marks(for: $0)) }, uniquingKeysWith: { $0.union($1) }))
    }
    .task(id: currentRequest) {
      let snapshot = currentRequest
      previewRequest = nil
      let preview = await Task.detached(priority: .userInitiated) {
        BatchRenamePlanner.plan(urls: urls, options: snapshot.options, classifications: snapshot.classifications)
      }.value
      guard !Task.isCancelled else { return }
      plan = preview
      previewRequest = snapshot
    }
    .alert("이름을 변경할 수 없음", isPresented: Binding(
      get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
    )) {
      Button("확인", role: .cancel) {}
    } message: { Text(errorMessage ?? "") }
  }

  private func classificationTitle(_ slot: PhotoMarkSlot) -> String {
    let label = classifications?.labels[slot] ?? slot.defaultLabel
    let visibleLabel = label.isEmpty ? BatchRenameL10n.text("classification.unnamed") : label
    let count = classifications?.marksByURL.values.filter { $0.contains(slot) }.count ?? 0
    return BatchRenameL10n.format("classification.option", slot.keyLabel, visibleLabel, count)
  }

  private func numberField(_ title: LocalizedStringKey, text: Binding<String>) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title).font(.caption)
      TextField(title, text: text)
        .frame(width: 90)
    }
  }

  private func apply() {
    guard let plan, numbersAreValid, previewRequest == currentRequest, plan.canApply else { return }
    Task {
      do {
        try await store.renameSelectedFiles(using: plan)
        dismiss()
      } catch {
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        previewRequest = nil
        self.plan = nil
        // Keep the sheet open, requiring a fresh preview after a filesystem conflict.
        let snapshot = currentRequest
        self.plan = await Task.detached {
          BatchRenamePlanner.plan(urls: urls, options: snapshot.options, classifications: snapshot.classifications)
        }.value
        previewRequest = snapshot
      }
    }
  }
}
