import Foundation

/// The machine-learning models the lab can use. None ships with it: each is downloaded the first time something
/// needs it, into `data/models/<name>/`, checked against the sizes and SHA-256s below, compiled once and kept.
///
/// Every URL is pinned to a commit, so a file can't change under its checksum. Sizes and checksums are from the
/// Hugging Face API (an LFS file's oid is its SHA-256) or, for small non-LFS files, hashed by hand (2026-11-07).
nonisolated public struct ModelSpec: Sendable, Codable {
    public struct File: Sendable, Codable {
        public var path: String          // where it lands inside the model's folder
        public var url: String
        public var size: Int
        public var sha256: String
    }

    public enum Format: String, Sendable, Codable {
        case mlpackage                   // files make up `<name>.mlpackage`, compiled to `<name>.mlmodelc`
        case zippedMLPackage             // one zip holding an .mlpackage, unzipped then compiled
        case data                        // plain files (a tokenizer's vocabulary), used as they are
    }

    public var name: String
    public var purpose: String
    public var format: Format
    public var licence: String
    public var source: String            // the page to read about it
    public var files: [File]
    /// Where Core ML runs it: `all` (the Neural Engine where it can) or `cpuAndGPU`. Big image-to-image networks
    /// run on the GPU: loading BiRefNet with `all` had the system's ANE compiler busy for over four minutes
    /// without finishing (and its conversion's metadata recommends CPU only), where the GPU loads in seconds.
    public var computeUnits = "all"

    public var size: Int { files.reduce(0) { $0 + $1.size } }
}

nonisolated public enum ModelManifest {
    static let clipCommit = "3e0a7bfb9fe83da8a3efaa3fd8f7df24214bb947"
    static let samCommit = "883f5787eb0be35ce6965907a8bc1f5320a5a02e"
    static func sam(_ path: String) -> String { "https://huggingface.co/apple/coreml-sam2.1-small/resolve/\(samCommit)/\(path)" }
    static func clip(_ path: String) -> String { "https://huggingface.co/apple/coreml-mobileclip/resolve/\(clipCommit)/\(path)" }

    public static let all: [ModelSpec] = [
        ModelSpec(
            name: "mobileclip-s2-image", purpose: "Says what kind of image it is (box, disc, logo, screenshot…) and finds similar images",
            format: .mlpackage, licence: "Apple ML Research Model licence (apple-amlr; research and personal use)",
            source: "https://huggingface.co/apple/coreml-mobileclip",
            files: [
                .init(path: "Manifest.json", url: clip("mobileclip_s2_image.mlpackage/Manifest.json"), size: 617,
                      sha256: "6a1a3f93b8dca6c237dbb5dc7b19bb3c987042d14860288304986c099d8796b6"),
                .init(path: "Data/com.apple.CoreML/model.mlmodel", url: clip("mobileclip_s2_image.mlpackage/Data/com.apple.CoreML/model.mlmodel"),
                      size: 299_056, sha256: "2aeb3359f6cde65e9f9248ec2a742e9939bd4bbf48c2f55fcd255b4504d96a1b"),
                .init(path: "Data/com.apple.CoreML/weights/weight.bin",
                      url: clip("mobileclip_s2_image.mlpackage/Data/com.apple.CoreML/weights/weight.bin"),
                      size: 71_397_632, sha256: "6cbc7fb06b6072c1cae9c4496d67e0e6217adbf726dfeb82e44d4efe87c34c00"),
            ]),
        ModelSpec(
            name: "mobileclip-s2-text", purpose: "Turns the descriptions of each kind of image into something images can be compared with",
            format: .mlpackage, licence: "Apple ML Research Model licence (apple-amlr; research and personal use)",
            source: "https://huggingface.co/apple/coreml-mobileclip",
            files: [
                .init(path: "Manifest.json", url: clip("mobileclip_s2_text.mlpackage/Manifest.json"), size: 617,
                      sha256: "ea6a189d82fee2ee36eadb99022cda66a7f6b50a4bf9cc1d9541c7ea3b4242a0"),
                .init(path: "Data/com.apple.CoreML/model.mlmodel", url: clip("mobileclip_s2_text.mlpackage/Data/com.apple.CoreML/model.mlmodel"),
                      size: 128_127, sha256: "b8651b6d030bae419a9548b41c8fae11f96b59cfa21b6e532a4c4434522b4b80"),
                .init(path: "Data/com.apple.CoreML/weights/weight.bin",
                      url: clip("mobileclip_s2_text.mlpackage/Data/com.apple.CoreML/weights/weight.bin"),
                      size: 126_866_880, sha256: "8e8d5454f104b6cbb58d98bf11e038ff1f1943599efea111260a832f094cd0ce"),
            ]),
        ModelSpec(
            name: "clip-tokenizer", purpose: "CLIP's word pieces, for the text model",
            format: .data, licence: "MIT (OpenAI CLIP)", source: "https://huggingface.co/openai/clip-vit-base-patch32",
            files: [
                .init(path: "vocab.json",
                      url: "https://huggingface.co/openai/clip-vit-base-patch32/resolve/3d74acf9a28c67741b2f4f2ea7635f0aaf6f0268/vocab.json",
                      size: 862_328, sha256: "5047b556ce86ccaf6aa22b3ffccfc52d391ea4accdab9c2f2407da5b742d4363"),
                .init(path: "merges.txt",
                      url: "https://huggingface.co/openai/clip-vit-base-patch32/resolve/3d74acf9a28c67741b2f4f2ea7635f0aaf6f0268/merges.txt",
                      size: 524_657, sha256: "f526393189112391ce6f9795d4695f704121ce452c3aad1f5335cc41337eba85"),
            ]),
        ModelSpec(
            name: "birefnet-lite", purpose: "Cuts the subject out of an image (a second opinion on the subject mask)",
            format: .mlpackage, licence: "MIT (BiRefNet; Core ML conversion by miracle2k)",
            source: "https://huggingface.co/getcay/birefnet-lite-coreml",
            files: [
                .init(path: "Manifest.json",
                      url: "https://huggingface.co/getcay/birefnet-lite-coreml/resolve/87771a8b6b4379857b6ef6597d1cac55562a6bf1/BiRefNetLite-1024-FP16Compute-FP32IO.mlpackage/Manifest.json",
                      size: 617, sha256: "c39212792a938d5cf424d40a3159b9dc18900ba03ae2d44f5f3791c172358c78"),
                .init(path: "Data/com.apple.CoreML/model.mlmodel",
                      url: "https://huggingface.co/getcay/birefnet-lite-coreml/resolve/87771a8b6b4379857b6ef6597d1cac55562a6bf1/BiRefNetLite-1024-FP16Compute-FP32IO.mlpackage/Data/com.apple.CoreML/model.mlmodel",
                      size: 3_287_769, sha256: "7652ec19a5eb62217a2428be416c2bce5103a249afd203d397638e03f1b8a58c"),
                .init(path: "Data/com.apple.CoreML/weights/weight.bin",
                      url: "https://huggingface.co/getcay/birefnet-lite-coreml/resolve/87771a8b6b4379857b6ef6597d1cac55562a6bf1/BiRefNetLite-1024-FP16Compute-FP32IO.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
                      size: 92_087_344, sha256: "db2e2a429f5b0f20d2d65f95bfd9517648a977aa73da71e4eaf0a95175312565"),
            ], computeUnits: "cpuAndGPU"),
        ModelSpec(
            name: "realesrgan-x4plus", purpose: "Makes small scans and low-resolution box art four times larger (not for pixel art)",
            format: .zippedMLPackage, licence: "BSD-3-Clause (Real-ESRGAN)",
            source: "https://huggingface.co/VincentGOURBIN/RealESRGAN-CoreML",
            files: [
                .init(path: "RealESRGAN-x4plus.mlpackage.zip",
                      url: "https://huggingface.co/VincentGOURBIN/RealESRGAN-CoreML/resolve/da0d01ce79946e6a62563eaf900ff9844af1f67f/RealESRGAN-x4plus.mlpackage.zip",
                      size: 30_996_079, sha256: "61d44a58bb8549a0c0485c95d2b384c598b48a648231206b3e7c2ac221e64599"),
            ], computeUnits: "cpuAndGPU"),
        ModelSpec(
            name: "sam2.1-small-image-encoder", purpose: "Works out what's where in a picture, once per picture, for picking parts of it",
            format: .mlpackage, licence: "Apache-2.0 (SAM 2.1, Meta; Core ML conversion by Apple)",
            source: "https://huggingface.co/apple/coreml-sam2.1-small",
            files: [
                .init(path: "Manifest.json", url: sam("SAM2_1SmallImageEncoderFLOAT16.mlpackage/Manifest.json"), size: 617,
                      sha256: "442f9102d1a37c2699fce89b1f5257d35ebd0a7096f1773501cb0aba94fe95b6"),
                .init(path: "Data/com.apple.CoreML/model.mlmodel", url: sam("SAM2_1SmallImageEncoderFLOAT16.mlpackage/Data/com.apple.CoreML/model.mlmodel"),
                      size: 203_631, sha256: "736602a3130875072f843df123ce3ceff41ec2f917a867da56f7c2264d81a567"),
                .init(path: "Data/com.apple.CoreML/weights/weight.bin", url: sam("SAM2_1SmallImageEncoderFLOAT16.mlpackage/Data/com.apple.CoreML/weights/weight.bin"),
                      size: 81_268_288, sha256: "6128a58f10cbcb7797bd12a7ec1e05ab4e9f8c80bd14ed05bbc43a9c9935a9c3"),
            ], computeUnits: "cpuAndGPU"),
        ModelSpec(
            name: "sam2.1-small-prompt-encoder", purpose: "Turns clicks and boxes on a picture into what the part picker understands",
            format: .mlpackage, licence: "Apache-2.0 (SAM 2.1, Meta; Core ML conversion by Apple)",
            source: "https://huggingface.co/apple/coreml-sam2.1-small",
            files: [
                .init(path: "Manifest.json", url: sam("SAM2_1SmallPromptEncoderFLOAT16.mlpackage/Manifest.json"), size: 617,
                      sha256: "b368a8e831599464347890a79c054df143c163d9928e3e0a2ab6ef7c00a425d4"),
                .init(path: "Data/com.apple.CoreML/model.mlmodel", url: sam("SAM2_1SmallPromptEncoderFLOAT16.mlpackage/Data/com.apple.CoreML/model.mlmodel"),
                      size: 20_618, sha256: "3a83c167d8bd63e80f86349a78c2ab0527ce97eca1f848a4ce57fe5351241fa3"),
                .init(path: "Data/com.apple.CoreML/weights/weight.bin", url: sam("SAM2_1SmallPromptEncoderFLOAT16.mlpackage/Data/com.apple.CoreML/weights/weight.bin"),
                      size: 2_101_056, sha256: "e29c6c65ef7754f8f6ed26155ca39ea703de3a7f576be5a7d3b8e29545059f31"),
            ], computeUnits: "cpuAndGPU"),
        ModelSpec(
            name: "sam2.1-small-mask-decoder", purpose: "Gives the part of a picture someone clicked on, at three sizes",
            format: .mlpackage, licence: "Apache-2.0 (SAM 2.1, Meta; Core ML conversion by Apple)",
            source: "https://huggingface.co/apple/coreml-sam2.1-small",
            files: [
                .init(path: "Manifest.json", url: sam("SAM2_1SmallMaskDecoderFLOAT16.mlpackage/Manifest.json"), size: 617,
                      sha256: "d95d732931f590dbf6a08ea1fe58a6659ced8971c5b2a671d79091be1a63b9e1"),
                .init(path: "Data/com.apple.CoreML/model.mlmodel", url: sam("SAM2_1SmallMaskDecoderFLOAT16.mlpackage/Data/com.apple.CoreML/model.mlmodel"),
                      size: 75_167, sha256: "3536b71674dc706381f42833b55627fd3d1f2c1b68a365b49255284b4f7b55c7"),
                .init(path: "Data/com.apple.CoreML/weights/weight.bin", url: sam("SAM2_1SmallMaskDecoderFLOAT16.mlpackage/Data/com.apple.CoreML/weights/weight.bin"),
                      size: 10_222_400, sha256: "dbc4910c434fee657ed9f001da7abcb467d2a37ac235099c6aa47628b122ec4e"),
            ], computeUnits: "cpuAndGPU"),
    ]

    public static func spec(_ name: String) -> ModelSpec? { all.first { $0.name == name } }
}
