// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CameraKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CameraCore", targets: ["CameraCore"]),
        .library(name: "DashboardUI", targets: ["DashboardUI"]),
        .library(name: "SonyPTP", targets: ["SonyPTP"]),
        .library(name: "SSHTunnel", targets: ["SSHTunnel"]),
        .library(name: "BlackmagicRESTBackend", targets: ["BlackmagicRESTBackend"]),
        .library(name: "BlackmagicBLE", targets: ["BlackmagicBLE"]),
        .library(name: "SonySavona", targets: ["SonySavona"]),
        .library(name: "ArriWebRemote", targets: ["ArriWebRemote"]),
        .executable(name: "dashboard-snapshot", targets: ["DashboardSnapshot"]),
        .executable(name: "camctl", targets: ["camctl"]),
        .executable(name: "sshtunnel-probe", targets: ["SSHTunnelProbe"]),
        .executable(name: "twcc-api-demo", targets: ["twcc-api-demo"]),
    ],
    targets: [
        // Vendor-neutral camera model, the CameraBackend protocol, and the mock backend.
        // Resources: Tiles' false color LUT (scripts/make-false-color-lut.py), loaded onto cameras without one; the Terms
        // of Use, Tiles' license and the third-party notices (`TermsOfUse`; the repo's LICENSE and NOTICE match them).
        .target(name: "CameraCore", resources: [
            .copy("Resources/TW False Color SLog3.cube"), .copy("Resources/TermsOfUse.md"),
            .copy("Resources/License.txt"), .copy("Resources/Acknowledgements.txt"),
        ]),
        // The SwiftUI dashboard. Lives in the package so it builds and renders headlessly.
        .target(name: "DashboardUI", dependencies: ["CameraCore"]),
        // Rules of the tile design system that hold without drawing anything (Dynamic Text Size's scale).
        .testTarget(name: "DashboardUITests", dependencies: ["DashboardUI", "CameraCore"]),
        // Renders the dashboard to a PNG on any Mac: `swift run dashboard-snapshot out.png 1920 1180`.
        .executableTarget(name: "DashboardSnapshot", dependencies: ["CameraCore", "DashboardUI", "BlackmagicRESTBackend"]),
        .target(name: "CameraKitTestSupport", dependencies: ["CameraCore"]),
        .testTarget(name: "CameraCoreTests", dependencies: ["CameraCore", "CameraKitTestSupport"]),
        .executableTarget(name: "twcc-api-demo", dependencies: ["CameraCore"]),

        // Blackmagic REST + WebSocket backend.
        .target(name: "BlackmagicRESTBackend", dependencies: ["CameraCore"]),
        .testTarget(name: "BlackmagicRESTTests", dependencies: ["BlackmagicRESTBackend", "CameraCore", "CameraKitTestSupport"],
                    exclude: ["Fixtures/key.pem", "Fixtures/cert.pem", "Fixtures/README.md"],
                    resources: [.copy("Fixtures/test-identity.p12"), .copy("Fixtures/pyxis-stream.flv"),
                                .copy("Fixtures/pyxis-10.3.1.cset")]),

        // Blackmagic over Bluetooth LE: the camera control protocol (URSA Mini Pro 12K, Pocket cameras, and the
        // PYXIS / URSA Cine, which take it too). The protocol and the backend build anywhere; the link is CoreBluetooth.
        .target(name: "BlackmagicBLE", dependencies: ["CameraCore"]),
        .testTarget(name: "BlackmagicBLETests", dependencies: ["BlackmagicBLE", "CameraCore", "CameraKitTestSupport"]),

        // --- SSH tunnel -------------------------------------------------------
        // libssh2 1.11.1 with OpenSSL 3.5.9, built by scripts/build-cssh.sh (licenses in NOTICE).
        // From this repository's releases.
        .binaryTarget(
            name: "CSSH",
            url: "https://github.com/williamjvest/tiles/releases/download/cssh-1.11.1-openssl-3.5.9/CSSH-1.11.1-OpenSSL-3.5.9.xcframework.zip",
            checksum: "f3fc0a52c24bc3b2dec0689208ffbba2363959217f773c82cf0bf8068e90ab6d"
        ),
        .target(
            name: "SSHTunnel",
            dependencies: ["CSSH"],
            swiftSettings: [
                .swiftLanguageMode(.v5)   // libssh2 C types need Sendable escape hatch
            ]
        ),
        .executableTarget(
            name: "SSHTunnelProbe",
            dependencies: ["SSHTunnel"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(name: "SSHTunnelTests", dependencies: ["SSHTunnel"]),

        // Sony VENICE / VENICE 2 over the Web Remote's Savona API (docs/venice.md).
        .target(name: "SonySavona", dependencies: ["CameraCore"]),
        .testTarget(name: "SonySavonaTests", dependencies: ["SonySavona", "CameraCore", "CameraKitTestSupport"]),

        // ARRI (ALEXA Mini, Mini LF, ALEXA 35, AMIRA) over the Web Remote's HTTP interface (docs/arri.md).
        .target(name: "ArriWebRemote", dependencies: ["CameraCore"]),
        .testTarget(name: "ArriWebRemoteTests", dependencies: ["ArriWebRemote", "CameraCore", "CameraKitTestSupport"]),

        // Sony PTP-IP network backend.
        .target(
            name: "SonyPTP",
            dependencies: ["CameraCore", "SSHTunnel"]
        ),
        // CLI camera control tool.
        .executableTarget(
            name: "camctl",
            dependencies: ["SonyPTP", "CameraCore", "BlackmagicRESTBackend", "SonySavona", "ArriWebRemote"]
        ),
        // SonyPTP tests including fake camera.
        .testTarget(
            name: "SonyPTPTests",
            dependencies: ["SonyPTP", "CameraCore", "CameraKitTestSupport"]
        ),
    ]
)
