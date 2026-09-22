// swift-tools-version: 6.0

import PackageDescription
import Foundation

let rustLibraryDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  .appendingPathComponent(".build/rust/lib").path

let package = Package(
  name: "ImageViewer",
  defaultLocalization: "ko",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(name: "ImageViewer", targets: ["ImageViewer"])
  ],
  targets: [
    .target(name: "CAlmaengCore", path: "Sources/CAlmaengCore", publicHeadersPath: "include"),
    .executableTarget(
      name: "ImageViewer",
      dependencies: ["CAlmaengCore"],
      path: "Sources/ImageViewer",
      resources: [
        .process("Resources")
      ],
      linkerSettings: [
        .unsafeFlags(["-L", rustLibraryDirectory]),
        .linkedLibrary("almeng_core"),
        .linkedFramework("AppKit"),
        .linkedFramework("CoreImage"),
        .linkedFramework("ImageIO"),
        .linkedFramework("QuickLookThumbnailing"),
        .linkedFramework("QuartzCore"),
      ]
    ),
    .testTarget(
      name: "ImageViewerTests",
      dependencies: ["ImageViewer"],
      path: "Tests/ImageViewerTests"
    ),
  ]
)
