import Foundation

#if canImport(UIKit)
import Photos
import UIKit

@MainActor
enum BagPhotoLibrary {
    static func saveCapturedImageToLibrary(_ image: UIImage) async -> String? {
        let status = await requestAddAccess()
        guard status == .authorized || status == .limited else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            let identifierBox = PhotoAssetIdentifierBox()
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetChangeRequest.creationRequestForAsset(from: image)
                identifierBox.value = request.placeholderForCreatedAsset?.localIdentifier
            } completionHandler: { success, _ in
                continuation.resume(returning: success ? identifierBox.value : nil)
            }
        }
    }

    static func image(for assetIdentifier: String, targetSize: CGSize) async -> UIImage? {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetIdentifier], options: nil)
        guard let asset = assets.firstObject else {
            return nil
        }

        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true

        return await withCheckedContinuation { continuation in
            var didResume = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !didResume, !isDegraded else { return }
                didResume = true
                continuation.resume(returning: image)
            }
        }
    }

    private static func requestAddAccess() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard current == .notDetermined else {
            return current
        }

        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status)
            }
        }
    }
}

private final class PhotoAssetIdentifierBox: @unchecked Sendable {
    var value: String?
}
#endif
