// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TruongScalerPackage",
    platforms: [
        .iOS("26.0"),
        .macOS("26.0")
    ],
    products: [
        .library(name: "TruongScalerCore", targets: ["TruongScalerCore"]),
        .library(name: "DeepZoomGalleryUI", targets: ["DeepZoomGalleryUI"]),
        .library(name: "ScalerActivityUI", targets: ["ScalerActivityUI"]),
        // Exposed explicitly so the app target can register/route background tasks without
        // relying on the transitive DeepZoomGalleryUI dependency.
        .library(name: "BackgroundJobManager", targets: ["BackgroundJobManager"])
    ],
    targets: [
        .target(
            name: "TruongScalerCore",
            dependencies: []
        ),
        .target(name: "ScalerActivityUI", dependencies: ["TruongScalerCore"]),
        .target(
            name: "MMapCanvas",
            dependencies: ["TruongScalerCore"]
        ),
        .target(
            name: "CoreIngestion",
            dependencies: ["TruongScalerCore", "MMapCanvas", "DNGWriterBridge"],
            swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]
        ),
        .target(
            name: "MetalColorEngine",
            dependencies: ["TruongScalerCore", "MMapCanvas"],
            resources: [.process("Shaders")],
            // Image arithmetic must remain representative on a phone launched with Xcode Run.
            // Keep normal -O checks; never use -Ounchecked or fast-math. UI stays unoptimized.
            swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]
        ),
        .target(
            name: "TiledInferenceEngine",
            dependencies: ["TruongScalerCore", "MMapCanvas", "CoreIngestion", "MetalColorEngine"],
            swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]
        ),
        .target(
            name: "DNGWriterBridge",
            dependencies: [],
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("include"),
                .unsafeFlags(["-std=c++17"])
            ]
        ),
        .target(
            name: "CoreExport",
            dependencies: ["TruongScalerCore", "MMapCanvas", "MetalColorEngine", "TiledInferenceEngine", "CoreIngestion", "DNGWriterBridge"],
            swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]
        ),
        .target(
            name: "BackgroundJobManager",
            dependencies: ["TruongScalerCore", "TiledInferenceEngine"]
        ),
        .target(
            name: "DeepZoomGalleryUI",
            dependencies: [
                "TruongScalerCore",
                "MMapCanvas",
                "CoreIngestion",
                "MetalColorEngine",
                "TiledInferenceEngine",
                "CoreExport",
                "BackgroundJobManager"
            ]
        ),
        .testTarget(name: "TruongScalerCoreTests", dependencies: ["TruongScalerCore"]),
        .testTarget(name: "MMapCanvasTests", dependencies: ["MMapCanvas", "TruongScalerCore"]),
        .testTarget(name: "CoreIngestionTests", dependencies: ["CoreIngestion", "MMapCanvas", "TruongScalerCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "MetalColorEngineTests", dependencies: ["MetalColorEngine", "MMapCanvas", "TruongScalerCore"]),
        .testTarget(name: "TiledInferenceEngineTests", dependencies: ["TiledInferenceEngine", "MetalColorEngine", "CoreIngestion", "CoreExport", "MMapCanvas", "TruongScalerCore"], resources: [.copy("Fixtures")]),
        .testTarget(
            name: "DNGWriterBridgeTests",
            dependencies: ["DNGWriterBridge", "CoreIngestion", "TruongScalerCore", "MMapCanvas"]
        ),
        .testTarget(name: "CoreExportTests", dependencies: ["CoreExport", "TiledInferenceEngine", "CoreIngestion", "MMapCanvas", "TruongScalerCore"]),
        .testTarget(
            name: "BackgroundJobManagerTests",
            dependencies: ["BackgroundJobManager", "TiledInferenceEngine", "TruongScalerCore"]
        ),
        .testTarget(
            name: "DeepZoomGalleryUITests",
            dependencies: [
                "DeepZoomGalleryUI",
                "TruongScalerCore",
                "MMapCanvas",
                "CoreIngestion",
                "CoreExport",
                "TiledInferenceEngine",
                "BackgroundJobManager",
                "ScalerActivityUI",
            ]
        )
    ]
)
