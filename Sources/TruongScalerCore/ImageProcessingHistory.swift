import Foundation

/// Interoperable, ordered processing evidence. No paths, file names, pixels or device identifiers.
/// Missing history means unknown history, not an unprocessed original. Legacy flags stay separate.
public struct ImageProcessingHistory: Codable, Sendable, Equatable {
    public struct Step: Codable, Sendable, Equatable {
        public let id: UUID
        public let app: String
        public let operation: String
        public let model: String?
        public let scale: Int?
        public let date: Date?
        public let inputWidth: Int
        public let inputHeight: Int
        public let outputWidth: Int
        public let outputHeight: Int
        public init(id: UUID, app: String, operation: String, model: String? = nil, scale: Int? = nil, date: Date? = nil,
                    inputWidth: Int, inputHeight: Int, outputWidth: Int, outputHeight: Int) {
            self.id = id; self.app = app; self.operation = operation; self.model = model; self.scale = scale; self.date = date
            self.inputWidth = inputWidth; self.inputHeight = inputHeight; self.outputWidth = outputWidth; self.outputHeight = outputHeight
        }
    }
    public let version: Int
    public let steps: [Step]
    public init(steps: [Step] = []) { version = 1; self.steps = Array(steps.suffix(32)) }
    public func appending(_ step: Step) -> Self {
        guard !steps.contains(where: { $0.id == step.id && $0.app == step.app && $0.operation == step.operation }) else { return self }
        return Self(steps: steps + [step])
    }
    private var valid: Bool {
        version == 1 && steps.count <= 32 && steps.allSatisfy {
            !$0.app.isEmpty && $0.app.utf8.count <= 128 && !$0.operation.isEmpty && $0.operation.utf8.count <= 64
                && ($0.model?.utf8.count ?? 0) <= 128 && ($0.scale == nil || (1...8).contains($0.scale!))
                && [$0.inputWidth, $0.inputHeight, $0.outputWidth, $0.outputHeight].allSatisfy { (1...1_000_000).contains($0) }
                && ($0.date?.timeIntervalSince1970.isFinite ?? true)
        }
    }
    public var marker: String? {
        guard valid else { return nil }
        // This marker is embedded in exported bytes. Equivalent history must produce identical
        // bytes across save retries, independent of keyed-container enumeration order.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self), data.count <= 16384 else { return nil }
        return "ProcessingHistoryV1=" + data.base64EncodedString()
    }
    public static func parse(_ raw: String) -> Self? {
        guard raw.utf8.count <= 1024 * 1024 else { return nil }
        // Case is significant in base64. Never pass normalized/lowercased marker text here.
        guard let range = raw.range(of: "ProcessingHistoryV1=") else { return nil }
        let encoded = raw[range.upperBound...].prefix { $0.isASCII && ($0.isLetter || $0.isNumber || "+/=".contains($0)) }
        guard encoded.count <= 22000, let data = Data(base64Encoded: String(encoded)), data.count <= 16384,
              let result = try? JSONDecoder().decode(Self.self, from: data), result.valid else { return nil }
        return result
    }
}
