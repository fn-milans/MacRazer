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
        // Razer's HID protocol: report framing, command builders and parsers, the Bluetooth
        // translation, onboard tables, the device registry. Pure; no AppKit, no IOKit.
        .target(
            name: "RazerProtocol",
            path: "Sources/RazerProtocol"
        ),
        // Talking to the hardware: USB HID and Bluetooth LE transports, device discovery and
        // monitoring, and the probes the CLI runs.
        .target(
            name: "RazerDeviceKit",
            dependencies: ["RazerProtocol"],
            path: "Sources/RazerDeviceKit"
        ),
        .executableTarget(
            name: "Serpentine",
            dependencies: ["RazerProtocol", "RazerDeviceKit"],
            path: "Sources/Serpentine"
        ),
        // Tests import the executable target directly (@testable) — supported by SwiftPM on
        // macOS, and avoids splitting a library target just to gain testability.
        .testTarget(
            name: "RazerProtocolTests",
            dependencies: ["RazerProtocol"],
            path: "Tests/RazerProtocolTests"
        ),
        .testTarget(
            name: "RazerDeviceKitTests",
            dependencies: ["RazerDeviceKit", "RazerProtocol"],
            path: "Tests/RazerDeviceKitTests"
        ),
        .testTarget(
            name: "SerpentineTests",
            dependencies: ["Serpentine", "RazerProtocol", "RazerDeviceKit"],
            path: "Tests/SerpentineTests"
        ),
    ]
)
