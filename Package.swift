// swift-tools-version: 6.0

import PackageDescription

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
    .executableTarget(
      name: "ImageViewer",
      path: "Sources/ImageViewer",
      linkerSettings: [
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
