import AppKit
import SwiftUI

/// The arrangement mirrors the twelve keys under the user's left hand.
/// No keyboard shortcuts are attached to these buttons: the window's existing
/// event monitor owns plain-key routing and leaves text entry alone.
struct PhotoMarkPanel: View {
  @ObservedObject var store: AppStore
  @ObservedObject var marks: PhotoMarkStore

  private let columns = Array(repeating: GridItem(.flexible(minimum: 78), spacing: 6), count: 4)

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if store.presentationMode == .folderComparison { targetPicker }
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .center, spacing: 18) {
          summary.frame(width: 190, alignment: .leading)
          keyboard.frame(minWidth: 330, maxWidth: 660)
          closeButton
        }
        VStack(alignment: .leading, spacing: 10) {
          HStack(alignment: .top) {
            summary
            Spacer(minLength: 12)
            closeButton
          }
          keyboard
        }
      }
      if store.presentationMode == .overview
        || (store.presentationMode == .viewer && store.imagesPerPage > 1) {
        Label(PhotoMarkL10n.text("panel.selectionHint"), systemImage: "checkmark.square")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      if store.presentationMode == .folderComparison
        ? (store.folderComparison.first.photoMarkFilter.isActive || store.folderComparison.second.photoMarkFilter.isActive)
        : store.photoMarkFilter.isActive {
        Text(PhotoMarkL10n.text("panel.filterStable"))
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      if let error = marks.errorMessage {
        Text(error)
          .font(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(ViewerTheme.panelGradient)
    .overlay(alignment: .top) { Rectangle().fill(ViewerTheme.separator).frame(height: 1) }
  }

  private var targetPicker: some View {
    HStack(spacing: 10) {
      Text(PhotoMarkL10n.text("target.title"))
        .font(.caption.weight(.medium))
      Picker(PhotoMarkL10n.text("target.title"), selection: Binding(
        get: { store.folderComparison.photoMarkTarget },
        set: {
          store.folderComparison.photoMarkTarget = $0
          store.clearPhotoMarkTextFocus(in: NSApp?.keyWindow)
        }
      )) {
        ForEach(ComparisonPhotoMarkTarget.allCases) { target in
          Text(target.title).tag(target)
        }
      }
      .labelsHidden()
      .pickerStyle(.segmented)
      .frame(width: 270)
      .disabled(!store.canTogglePhotoMarking)
      .help(PhotoMarkL10n.text("target.help"))
      .accessibilityIdentifier("comparison.photoMarkTarget")
    }
  }

  private var summary: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 6) {
        Image(systemName: "tag")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(ViewerTheme.accent)
          .frame(width: 25, height: 25)
          .background(ViewerTheme.selection, in: RoundedRectangle(cornerRadius: 7))
          .accessibilityHidden(true)
        Text(PhotoMarkL10n.text("panel.title")).fontWeight(.semibold)
        if !marks.isReady && marks.errorMessage == nil {
          ProgressView().controlSize(.mini)
            .accessibilityLabel(PhotoMarkL10n.text("panel.loading"))
        }
      }
      Text(targetDescription)
        .font(.caption)
        .fontWeight(hasBatchSelection ? .semibold : .regular)
        .foregroundStyle(hasBatchSelection ? ViewerTheme.accent : Color.secondary)
        .lineLimit(store.presentationMode == .folderComparison
          && store.folderComparison.photoMarkTarget == .both ? 2 : 1)
        .truncationMode(.middle)
        .help(targetDescription)
        .accessibilityIdentifier("photoMark.targetSummary")
      Text(PhotoMarkL10n.text(
        store.presentationMode == .overview ? "panel.gridHint"
          : store.presentationMode == .viewer && store.imagesPerPage > 1
            ? "panel.viewerGridHint" : "panel.hint"))
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Button {
        store.presentPhotoMarkEditor()
      } label: {
        Label(PhotoMarkL10n.text("labels.edit"), systemImage: "pencil")
      }
      .controlSize(.small)
      .help(PhotoMarkL10n.text("labels.editHelp"))
      .disabled(!store.canEditPhotoMarkLabels)
      Button(BatchActionsL10n.text("report.menu")) { store.showsPhotoMarkTrackingReport = true }
        .controlSize(.small)
        .disabled(!store.canEditPhotoMarkLabels)
    }
    .font(.system(size: 12))
  }

  private var keyboard: some View {
    LazyVGrid(columns: columns, spacing: 6) {
      ForEach(PhotoMarkSlot.allCases, id: \.self) { slot in
        let state = store.photoMarkSelectionState(for: slot)
        let selected = state != .none
        let color = marks.color(for: slot)
        Button { store.togglePhotoMark(slot) } label: {
          HStack(spacing: 6) {
            PhotoMarkKeycap(key: slot.keyLabel, isSelected: selected, color: color)
            Text(displayName(for: slot, marks: marks))
              .font(.system(size: 11, weight: selected ? .semibold : .regular))
              .lineLimit(1)
              .truncationMode(.tail)
              .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: state == .mixed ? "minus" : "checkmark")
              .font(.system(size: 9, weight: .bold))
              .foregroundStyle(color.tint)
              .frame(width: 10)
              .opacity(selected ? 1 : 0)
          }
          .padding(.horizontal, 7)
          .frame(height: 31)
          .foregroundStyle(Color.primary)
          .background {
            RoundedRectangle(cornerRadius: 6).fill(ViewerTheme.controlFill)
              .overlay {
                RoundedRectangle(cornerRadius: 6).fill(color.tint.opacity(selected ? 0.18 : 0.045))
              }
          }
          .overlay {
            RoundedRectangle(cornerRadius: 6)
              .strokeBorder(color.tint.opacity(selected ? 0.85 : 0.25), lineWidth: selected ? 1.5 : 1)
          }
          .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(!store.canMarkPhoto)
        .help(PhotoMarkL10n.format(state == .all ? "mark.removeHelpFormat" : "mark.addHelpFormat",
          slot.keyLabel, displayName(for: slot, marks: marks)))
        .accessibilityLabel("\(slot.keyLabel) · \(displayName(for: slot, marks: marks))")
        .accessibilityValue("\(state == .mixed ? PhotoMarkL10n.text("target.mixed") : L10n.text(selected ? "선택됨" : "선택 안 됨")), \(color.title)")
        .accessibilityAddTraits(state == .all ? [.isSelected] : [])
        .accessibilityIdentifier("photoMark.panel.\(slot.rawValue)")
      }
    }
    .accessibilityHint(PhotoMarkL10n.text("panel.multipleHint"))
  }

  private var targetDescription: String {
    if store.presentationMode == .folderComparison {
      let comparison = store.folderComparison
      return comparison.photoMarkTarget.sides.map { side in
        "\(side.title(in: comparison.arrangement)) · \(comparison.pane(side).currentAsset?.filename ?? PhotoMarkL10n.text("panel.noPhoto"))"
      }.joined(separator: "\n")
    }
    if hasBatchSelection {
      return PhotoMarkL10n.format("panel.selectionFormat", store.photoMarkAssets.count)
    }
    if (store.presentationMode == .viewer || store.presentationMode == .overview),
      !store.assets.isEmpty, store.photoMarkAssets.isEmpty {
      return PhotoMarkL10n.text("panel.noSelection")
    }
    return store.photoMarkAsset?.filename ?? PhotoMarkL10n.text("panel.noPhoto")
  }

  private var hasBatchSelection: Bool {
    store.presentationMode != .folderComparison && store.photoMarkAssets.count > 1
  }

  private var closeButton: some View {
    Button { store.togglePhotoMarking() } label: {
      Image(systemName: "xmark")
        .font(.system(size: 10, weight: .semibold))
        .frame(width: 22, height: 22)
        .background(ViewerTheme.controlFill, in: RoundedRectangle(cornerRadius: 6))
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .help(PhotoMarkL10n.text("panel.close"))
    .accessibilityLabel(PhotoMarkL10n.text("panel.close"))
  }
}

/// Unlike a card's Tags menu, this checkbox only chooses the files that the
/// shared classification panel and its keyboard shortcuts will act on.
struct PhotoMarkSelectionToggle: View {
  let asset: ImageAsset
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: isSelected ? "checkmark.square.fill" : "square")
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(PhotoMarkL10n.text("selection.help"))
    .accessibilityLabel(PhotoMarkL10n.format("selection.accessibilityFormat", asset.filename))
    .accessibilityValue(L10n.text(isSelected ? "선택됨" : "선택 안 됨"))
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    .accessibilityIdentifier("photoMark.select.\(asset.sessionID)")
  }
}

struct PhotoMarkEditor: View {
  @ObservedObject var marks: PhotoMarkStore
  var isEmbedded = false
  @Environment(\.dismiss) private var dismiss
  @State private var draft: PhotoMarkLabelDraft

  init(marks: PhotoMarkStore, isEmbedded: Bool = false) {
    self.marks = marks
    self.isEmbedded = isEmbedded
    let names = Dictionary(uniqueKeysWithValues:
      PhotoMarkSlot.allCases.map { ($0, marks.label(for: $0)) })
    let colors = Dictionary(uniqueKeysWithValues:
      PhotoMarkSlot.allCases.map { ($0, marks.color(for: $0)) })
    _draft = State(initialValue: PhotoMarkLabelDraft(labels: names, colors: colors))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 9) {
        Image(systemName: "tag")
          .font(.system(size: 15, weight: .medium))
          .foregroundStyle(ViewerTheme.accent)
          .frame(width: 30, height: 30)
          .background(ViewerTheme.selection, in: RoundedRectangle(cornerRadius: 8))
          .accessibilityHidden(true)
        Text(PhotoMarkL10n.text("labels.title"))
          .font(.title3.weight(.semibold))
      }
      Text(PhotoMarkL10n.text("labels.hint"))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4), spacing: 14) {
        ForEach(PhotoMarkSlot.allCases, id: \.self) { slot in
          VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
              PhotoMarkKeycap(key: slot.keyLabel, isSelected: false,
                color: draft.colors[slot] ?? slot.defaultColor, width: 28, height: 25)
                .help(PhotoMarkL10n.format("labels.keyHelpFormat", slot.keyLabel))
              Spacer(minLength: 0)
              Picker(PhotoMarkL10n.format("colors.keyFormat", slot.keyLabel), selection: Binding(
                get: { draft.colors[slot] ?? slot.defaultColor },
                set: { draft.colors[slot] = $0 }
              )) {
                ForEach(PhotoMarkColor.allCases, id: \.self) { color in
                  PhotoMarkMenuLabel(name: color.title, color: color).tag(color)
                }
              }
              .labelsHidden()
              .pickerStyle(.menu)
              .controlSize(.small)
              .frame(maxWidth: 100)
              .help(PhotoMarkL10n.text("colors.help"))
            }
            TextField(PhotoMarkL10n.text("labels.placeholder"), text: Binding(
              get: { draft.labels[slot] ?? "" },
              set: { draft.labels[slot] = String($0.prefix(40)) }
            ))
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel(PhotoMarkL10n.format("labels.keyFormat", slot.keyLabel))
            .help(PhotoMarkL10n.format("labels.keyHelpFormat", slot.keyLabel))
          }
        }
      }
      VStack(alignment: .leading, spacing: 5) {
        Text(PhotoMarkL10n.text("labels.previewTitle"))
          .font(.caption.weight(.semibold))
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 4),
          alignment: .leading, spacing: 5) {
          ForEach(PhotoMarkSlot.allCases, id: \.self) { slot in
            let name = draft.labels[slot] ?? ""
            let preview = PhotoMarkL10n.format("labels.previewFormat", slot.keyLabel,
              name.isEmpty ? PhotoMarkL10n.text("labels.unnamed") : name)
            HStack(spacing: 5) {
              Circle().fill((draft.colors[slot] ?? slot.defaultColor).tint)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
              Text(preview)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
            }
            .help(preview)
          }
        }
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(ViewerTheme.controlFill, in: RoundedRectangle(cornerRadius: 8))
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(ViewerTheme.controlBorder, lineWidth: 1)
      }
      Text(PhotoMarkL10n.text("labels.safety"))
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      HStack {
        Spacer()
        Button(PhotoMarkL10n.text(isEmbedded ? "labels.revert" : "cancel")) {
          if isEmbedded { reloadLabels() } else { dismiss() }
        }
          .keyboardShortcut(.cancelAction)
          .help(PhotoMarkL10n.text(isEmbedded ? "labels.revertHelp" : "labels.cancelHelp"))
          .disabled(isEmbedded && !draft.hasChanges)
        Button(PhotoMarkL10n.text("save")) {
          marks.setDefinitions(labels: draft.applyingChanges(to: currentLabels),
            colors: draft.applyingColorChanges(to: currentColors))
          reloadLabels()
          if !isEmbedded { dismiss() }
        }
        .keyboardShortcut(.defaultAction)
        .help(PhotoMarkL10n.text("labels.saveHelp"))
        .disabled(!marks.isReady || !draft.hasChanges)
      }
    }
    .padding(isEmbedded ? 16 : 24)
    .frame(width: isEmbedded ? nil : 620)
    .onChange(of: marks.labels) { _, _ in
      draft.refresh(with: currentLabels, colors: currentColors)
    }
    .onChange(of: marks.colors) { _, _ in
      draft.refresh(with: currentLabels, colors: currentColors)
    }
  }

  private var currentLabels: [PhotoMarkSlot: String] {
    Dictionary(uniqueKeysWithValues:
      PhotoMarkSlot.allCases.map { ($0, marks.label(for: $0)) })
  }

  private func reloadLabels() {
    draft = PhotoMarkLabelDraft(labels: currentLabels, colors: currentColors)
  }

  private var currentColors: [PhotoMarkSlot: PhotoMarkColor] {
    Dictionary(uniqueKeysWithValues:
      PhotoMarkSlot.allCases.map { ($0, marks.color(for: $0)) })
  }
}

struct PhotoMarkSettingsView: View {
  @ObservedObject var marks: PhotoMarkStore
  @ObservedObject var preferences: PhotoMarkPreferences

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        inheritanceSettings
        Divider().padding(.horizontal, 16)
        Text(PhotoMarkL10n.text("settings.hint"))
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 16)
          .padding(.top, 12)
        if let error = marks.errorMessage {
          Text(error)
            .foregroundStyle(.red)
            .textSelection(.enabled)
            .padding(16)
        } else if marks.isReady {
          PhotoMarkEditor(marks: marks, isEmbedded: true)
        } else {
          ProgressView(PhotoMarkL10n.text("panel.loading"))
            .padding(16)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var inheritanceSettings: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(PhotoMarkL10n.text("inheritance.title"), systemImage: "doc.on.doc")
        .font(.headline)
      Toggle(PhotoMarkL10n.text("inheritance.copy"), isOn: $preferences.inheritOnCopy)
        .accessibilityIdentifier("settings.photoMarks.inheritOnCopy")
      Toggle(PhotoMarkL10n.text("inheritance.export"), isOn: $preferences.inheritOnExport)
        .accessibilityIdentifier("settings.photoMarks.inheritOnExport")
      Text(PhotoMarkL10n.text("inheritance.defaults"))
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Text(PhotoMarkL10n.text("inheritance.originals"))
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(16)
  }
}

struct PhotoMarkFilterMenu: View {
  @ObservedObject var store: AppStore
  @ObservedObject var marks: PhotoMarkStore

  var body: some View {
    Menu {
      ForEach(PhotoMarkSlot.allCases, id: \.self) { slot in
        Toggle(isOn: Binding(
          get: { store.photoMarkFilter.slots.contains(slot) },
          set: { enabled in
            var filter = store.photoMarkFilter
            if enabled {
              filter.slots.insert(slot)
              filter.unmarkedOnly = false
            } else {
              filter.slots.remove(slot)
            }
            store.photoMarkFilter = filter
          }
        )) {
          PhotoMarkMenuLabel(name: "\(slot.keyLabel) · \(displayName(for: slot, marks: marks))",
            color: marks.color(for: slot))
        }
      }
      Divider()
      Picker(PhotoMarkL10n.text("filter.title"), selection: Binding(
        get: { store.photoMarkFilter.matchesAll },
        set: { store.photoMarkFilter.matchesAll = $0 }
      )) {
        Text(PhotoMarkL10n.text("filter.any")).tag(false)
        Text(PhotoMarkL10n.text("filter.all")).tag(true)
      }
      .pickerStyle(.inline)
      .disabled(store.photoMarkFilter.unmarkedOnly)
      Toggle(PhotoMarkL10n.text("filter.unmarked"), isOn: Binding(
        get: { store.photoMarkFilter.unmarkedOnly },
        set: { enabled in
          var filter = store.photoMarkFilter
          filter.unmarkedOnly = enabled
          if enabled { filter.slots = [] }
          store.photoMarkFilter = filter
        }
      ))
      Divider()
      Button(PhotoMarkL10n.text("filter.reset")) { store.photoMarkFilter = PhotoMarkFilter() }
        .disabled(!store.photoMarkFilter.isActive)
      Button(PhotoMarkL10n.text("labels.edit")) { store.presentPhotoMarkEditor() }
        .disabled(!store.canEditPhotoMarkLabels)
    } label: {
      Label(menuTitle, systemImage: store.photoMarkFilter.isActive ? "tag.fill" : "tag")
        .lineLimit(1)
        .foregroundStyle(store.photoMarkFilter.isActive ? ViewerTheme.accent : Color.primary)
    }
    .fixedSize()
    .help(PhotoMarkL10n.text("filter.help"))
    .disabled(!marks.isReady || store.isBatchBusy || store.batchSheet != nil || store.isSavingMetadata || store.isExporting)
  }

  private var menuTitle: String {
    if store.photoMarkFilter.unmarkedOnly { return PhotoMarkL10n.text("filter.unmarkedTitle") }
    if !store.photoMarkFilter.slots.isEmpty {
      return PhotoMarkL10n.format("filter.activeFormat", store.photoMarkFilter.slots.count)
    }
    return PhotoMarkL10n.text("filter.title")
  }
}

struct PhotoMarkThumbnailBadges: View {
  @ObservedObject var marks: PhotoMarkStore
  let asset: ImageAsset

  private var assigned: [PhotoMarkSlot] {
    PhotoMarkSlot.allCases.filter { marks.marks(for: asset).contains($0) }
  }

  var body: some View {
    if !assigned.isEmpty {
      HStack(spacing: 3) {
        ForEach(Array(assigned.prefix(4)), id: \.self) { slot in
          Text(slot.keyLabel)
            .foregroundStyle(marks.color(for: slot).tint)
            .frame(minWidth: 14)
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
            .background(marks.color(for: slot).tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 3))
        }
        if assigned.count > 4 {
          Text(PhotoMarkL10n.format("badge.moreFormat", assigned.count - 4))
        }
      }
      .font(.system(size: 9, weight: .semibold, design: .monospaced))
      .foregroundStyle(.secondary)
      .help(assigned.map { displayName(for: $0, marks: marks) }.joined(separator: ", "))
      .accessibilityHidden(true)
    }
  }
}

/// A quiet, raised key shape keeps the shortcut separate from its editable label.
private struct PhotoMarkKeycap: View {
  let key: String
  let isSelected: Bool
  let color: PhotoMarkColor
  var width: CGFloat = 21
  var height: CGFloat = 22

  var body: some View {
    Text(key)
      .font(.system(size: 12, weight: .semibold, design: .monospaced))
      .foregroundStyle(color.tint)
      .frame(width: width, height: height)
      .background {
        RoundedRectangle(cornerRadius: 4).fill(ViewerTheme.panelGradient)
          .overlay {
            RoundedRectangle(cornerRadius: 4).fill(color.tint.opacity(isSelected ? 0.16 : 0.08))
          }
      }
      .overlay {
        RoundedRectangle(cornerRadius: 4)
          .strokeBorder(color.tint.opacity(isSelected ? 0.65 : 0.25), lineWidth: 1)
      }
      .shadow(color: .black.opacity(0.06), radius: 0, x: 0, y: 1)
  }
}

@MainActor
private func displayName(for slot: PhotoMarkSlot, marks: PhotoMarkStore) -> String {
  let name = marks.label(for: slot)
  return name.isEmpty ? PhotoMarkL10n.text("labels.unnamed") : name
}
