import Foundation

/// A versioned, offline-trained 16 → 32 → 16 → 1 metadata ranker.
/// Inference only on the device: no random retraining for each query, model
/// download, third-party account, or transfer of the user's playlist to an AI API.
enum DeviceNeuralTransferMatcher {
    static func match(prepared: String, catalogJSON: Data,
                      mode: String = "balanced") throws -> [[String: Any]] {
        try DeviceTransferMatcher.match(prepared: prepared, catalogJSON: catalogJSON,
                                        mode: mode, ranker: TransferNeuralModel.predict)
    }
}
