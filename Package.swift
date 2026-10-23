// swift-tools-version:6.1
// SPDX-License-Identifier: GPL-2.0-or-later
// Part of Serpentine, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.
import PackageDescription

let package = Package(
    name: "Serpentine",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Serpentine",
            path: "Sources/Serpentine"
        ),
        // Tests import the executable target directly (@testable) — supported by SwiftPM on
        // macOS, and avoids splitting a library target just to gain testability.
        .testTarget(
            name: "SerpentineTests",
            dependencies: ["Serpentine"],
            path: "Tests/SerpentineTests"
        ),
    ]
)
