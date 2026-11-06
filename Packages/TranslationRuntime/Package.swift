// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TranslationRuntime",
    platforms: [.macOS(.v15)],
    products: [.library(name: "TranslationRuntime", targets: ["TranslationRuntime"])],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3", traits: []),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.32.3"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.0")
    ],
    targets: [
        .target(name: "TranslationRuntime", dependencies: [
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "Tokenizers", package: "swift-transformers")
        ], path: "src"),
        .testTarget(name: "TranslationRuntimeTests", dependencies: [
            "TranslationRuntime",
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm")
        ], path: "Tests")
    ]
)
