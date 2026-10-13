import AppKit
import AVKit
import Combine
import SwiftUI

/// A separate native full-screen window keeps the gallery's page, layout and
/// selection intact. Only this window owns playback until it closes.
@MainActor
final class VideoFullScreenController: NSWindowController, NSWindowDelegate {
  let playback = VideoPlaybackState()
  let asset: ImageAsset
  private weak var store: AppStore?
  private let initialSeconds: Double
  private let initiallyMuted: Bool
  private var onClose: (() -> Void)?
  private weak var returnWindow: NSWindow?
  private var monitorTask: Task<Void, Never>?
  private var autoplayTask: Task<Void, Never>?
  private var eventMonitor: Any?
  private var subscriptions: Set<AnyCancellable> = []
  private var isEnteringFullScreen = false
  private var isClosing = false
  private var didFinish = false

  init(asset: ImageAsset, seconds: Double, isMuted: Bool, store: AppStore? = nil,
    onClose: @escaping () -> Void) {
    self.asset = asset
    self.store = store
    initialSeconds = seconds.isFinite ? max(0, seconds) : 0
    initiallyMuted = isMuted
    self.onClose = onClose
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
      styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.title = asset.filename
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.backgroundColor = .black
    window.isReleasedWhenClosed = false
    window.tabbingMode = .disallowed
    window.collectionBehavior = [.fullScreenPrimary]
    super.init(window: window)
    playback.player.isMuted = isMuted
    // Readiness changes inside AVKit, independently of AppStore. Republish only
    // those transitions so the classification menu enables as soon as it loads.
    playback.player.publisher(for: \.currentItem)
      .map { item -> AnyPublisher<AVPlayerItem.Status, Never> in
        guard let item else { return Just(.unknown).eraseToAnyPublisher() }
        return item.publisher(for: \.status).eraseToAnyPublisher()
      }
      .switchToLatest()
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in self?.store?.objectWillChange.send() }
      .store(in: &subscriptions)
    window.delegate = self
    window.contentView = NSHostingView(rootView: FullScreenVideoContent(
      asset: asset, playback: playback, store: store, onClose: { [weak self] in self?.requestClose() }))
  }

  required init?(coder: NSCoder) { nil }

  func present() {
    guard let window else { return }
    returnWindow = NSApp.keyWindow ?? NSApp.mainWindow
      ?? NSApp.orderedWindows.first { $0 !== window && $0.isVisible && $0.canBecomeMain }
    window.center()
    eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, event.window === self.window else { return event }
      if event.keyCode == 53 { self.requestClose(); return nil }
      if !(self.window?.firstResponder is NSTextView),
        self.store?.handleFullScreenPhotoMarkKeyDown(event) == true { return nil }
      return event
    }
    NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
      .sink { [weak self] _ in self?.pause() }.store(in: &subscriptions)
    NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
      .sink { [weak self] _ in self?.pause() }.store(in: &subscriptions)
    isEnteringFullScreen = true
    NSApp.activate()
    window.makeKeyAndOrderFront(nil)
    window.toggleFullScreen(nil)
  }

  func windowDidEnterFullScreen(_ notification: Notification) {
    isEnteringFullScreen = false
    if isClosing { window?.toggleFullScreen(nil); return }
    startPlayback()
  }

  func windowDidFailToEnterFullScreen(_ window: NSWindow) {
    isEnteringFullScreen = false
    if isClosing { window.close() }
    else { startPlayback() }
  }

  func windowDidExitFullScreen(_ notification: Notification) {
    // Let AppKit finish moving the window out of its Space before disposing it.
    DispatchQueue.main.async { [self] in window?.close() }
  }
  func windowDidResignKey(_ notification: Notification) {
    // AppKit resigns the old key window before installing a popover/sheet as
    // the new one. Inspect the completed transition rather than pausing while
    // the user is changing subtitle timing in our own child window.
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.didFinish, !self.isClosing, let window = self.window else { return }
      if Self.shouldPauseForFocusChange(isAppActive: NSApp.isActive,
        keyWindow: NSApp.keyWindow, playerWindow: window) { self.pause() }
    }
  }
  func windowWillClose(_ notification: Notification) { finish() }

  static func shouldPauseForFocusChange(isAppActive: Bool, keyWindow: NSWindow?,
    playerWindow: NSWindow) -> Bool {
    guard isAppActive else { return true }
    var ancestors = keyWindow.map { [$0] } ?? []
    var visited: Set<ObjectIdentifier> = []
    while let candidate = ancestors.popLast() {
      guard visited.insert(ObjectIdentifier(candidate)).inserted else { continue }
      if candidate === playerWindow { return false }
      if let parent = candidate.parent { ancestors.append(parent) }
      if let sheetParent = candidate.sheetParent { ancestors.append(sheetParent) }
    }
    return true
  }

  func requestClose() {
    guard !isClosing else { return }
    isClosing = true
    pause()
    guard !isEnteringFullScreen, let window else { return }
    if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
    else { window.close() }
  }

  private func startPlayback() {
    guard monitorTask == nil, !didFinish else { return }
    let playback = playback
    let asset = asset
    monitorTask = Task { await playback.monitor(asset) }
    autoplayTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self, !self.didFinish, !self.isClosing else { return }
        if playback.errorMessage != nil { return }
        if playback.player.currentItem?.status == .readyToPlay {
          guard NSApp.isActive, self.window?.isKeyWindow == true else { return }
          playback.player.isMuted = self.initiallyMuted
          // A preview may have just reached its end before the double-click.
          let duration = playback.document?.durationSeconds ?? 0
          let start = self.initialSeconds >= duration - 0.05 ? 0 : self.initialSeconds
          playback.play(from: start)
          return
        }
        do { try await Task.sleep(for: .milliseconds(30)) }
        catch { return }
      }
    }
  }

  private func pause() {
    autoplayTask?.cancel()
    autoplayTask = nil
    playback.pause()
  }

  private func finish() {
    guard !didFinish else { return }
    didFinish = true
    pause()
    monitorTask?.cancel()
    monitorTask = nil
    playback.stop()
    subscriptions.removeAll()
    if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    eventMonitor = nil
    window?.contentView = nil
    returnWindow?.makeKeyAndOrderFront(nil)
    let completion = onClose
    onClose = nil
    completion?()
  }
}

private struct FullScreenVideoContent: View {
  let asset: ImageAsset
  @ObservedObject var playback: VideoPlaybackState
  let store: AppStore?
  let onClose: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      // Keep controls outside the native player's hit region. Its double-click
      // monitor cannot distinguish SwiftUI controls painted over that region.
      HStack {
        Text(asset.filename).font(.callout).lineLimit(1).truncationMode(.middle)
        Spacer(minLength: 16)
        if let study = playback.study { VideoStudyControls(session: study) }
        if let store {
          FullScreenPhotoMarkControls(store: store, asset: asset)
        }
        Button(action: onClose) {
          Image(systemName: "xmark").font(.body.weight(.semibold)).frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .help(MotionMediaL10n.text("video.fullscreen.close") + " (Esc)")
        .accessibilityLabel(MotionMediaL10n.text("video.fullscreen.close"))
      }
      .foregroundStyle(.white).padding(12)
      .background(.black.opacity(0.55))

      Group {
        if let error = playback.errorMessage {
          ContentUnavailableView(MotionMediaL10n.text("video.unavailable"),
            systemImage: "film", description: Text(error))
        } else if playback.document != nil {
          StudyVideoPlayerView(playback: playback, onDoubleClick: onClose)
        } else {
          ProgressView()
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .clipped()
    }
    .background(.black)
    .environment(\.colorScheme, .dark)
  }
}

private struct FullScreenPhotoMarkControls: View {
  @ObservedObject var store: AppStore
  let asset: ImageAsset

  var body: some View {
    HStack(spacing: 8) {
      Button { store.togglePhotoMarking() } label: {
        Label(PhotoMarkL10n.text(store.isPhotoMarking ? "mode.on" : "mode.off"),
          systemImage: store.isPhotoMarking ? "tag.fill" : "tag")
      }
      .buttonStyle(ViewerToolButtonStyle(isSelected: store.isPhotoMarking))
      .disabled(!store.canTogglePhotoMarking)
      .help(PhotoMarkL10n.text("mode.help"))
      .accessibilityLabel(PhotoMarkL10n.text("mode.title"))
      .accessibilityValue(PhotoMarkL10n.text(store.isPhotoMarking ? "mode.on" : "mode.off"))
      if store.isPhotoMarking { PhotoMarkCardMenu(store: store, asset: asset) }
    }
  }
}
