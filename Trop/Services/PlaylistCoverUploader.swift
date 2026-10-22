//
//  PlaylistCoverUploader.swift
//  Trop
//

import Foundation
import UIKit

/// Sets a custom cover on a YouTube Music playlist, the same way the
/// music.youtube.com editor does: a resumable image upload returns a blob id,
/// then `browse/edit_playlist` attaches it with ACTION_SET_CUSTOM_THUMBNAIL.
/// This is an undocumented web flow; if YouTube changes it the upload fails
/// with an error and nothing else is touched.
enum PlaylistCoverUploader {
    enum UploadError: LocalizedError {
        case notSignedIn
        case unreadableImage
        case rejected(step: String)

        var errorDescription: String? {
            switch self {
            case .notSignedIn: "Sign in to YouTube Music in Settings to change playlist covers."
            case .unreadableImage: "This image can't be used. Try a different photo."
            case .rejected(let step): "YouTube Music refused the cover (\(step)). Try again later."
            }
        }
    }

    private static let origin = "https://music.youtube.com"
    private static let uploadURL = URL(string: origin + "/playlist_image_upload/playlist_custom_thumbnail")!
    /// Square side sent to YouTube; it serves the cover back at up to 544px.
    private static let coverSide: CGFloat = 1024

    /// Uploads `image` as the cover of `playlistId`, saves the new cover URL
    /// locally and returns it.
    @discardableResult
    static func setCover(_ image: UIImage, playlistId: String) async throws -> String? {
        guard let jpeg = squareJPEG(image) else { throw UploadError.unreadableImage }

        let store = CookieStore()
        let cookies = await store.cookies()
        guard !cookies.isEmpty, let sapisid = await store.sapisid() else { throw UploadError.notSignedIn }
        let cookieHeader = cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")

        func signedRequest(_ url: URL) -> URLRequest {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            request.setValue(SAPISIDAuth.authorizationHeader(sapisid: sapisid, origin: origin),
                             forHTTPHeaderField: "Authorization")
            request.setValue(origin, forHTTPHeaderField: "Origin")
            request.setValue(origin, forHTTPHeaderField: "X-Origin")
            request.setValue(origin + "/", forHTTPHeaderField: "Referer")
            request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
            request.setValue("application/x-www-form-urlencoded;charset=utf-8", forHTTPHeaderField: "Content-Type")
            return request
        }

        // 1. Open an upload session.
        var start = signedRequest(uploadURL)
        start.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        start.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        start.setValue(String(jpeg.count), forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        let (_, startResponse) = try await URLSession.shared.data(for: start)
        guard let http = startResponse as? HTTPURLResponse, http.statusCode == 200,
              let sessionURL = http.value(forHTTPHeaderField: "x-goog-upload-url").flatMap(URL.init(string:))
        else { throw UploadError.rejected(step: "upload start") }

        // 2. Send the image; the reply carries the blob id.
        var send = signedRequest(sessionURL)
        send.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        send.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        let (sendData, sendResponse) = try await URLSession.shared.upload(for: send, from: jpeg)
        guard (sendResponse as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: sendData) as? [String: Any],
              let blobId = json["encryptedBlobId"] as? String
        else { throw UploadError.rejected(step: "image upload") }

        // 3. Attach the uploaded image to the playlist.
        let response = try await InnerTubeClient.tropShared.editPlaylist(
            playlistId: playlistId.hasPrefix("VL") ? String(playlistId.dropFirst(2)) : playlistId,
            actions: [[
                "action": "ACTION_SET_CUSTOM_THUMBNAIL",
                "addedCustomThumbnail": [
                    "imageKey": [
                        "type": "PLAYLIST_IMAGE_TYPE_CUSTOM_THUMBNAIL",
                        "name": "studio_square_thumbnail"
                    ],
                    "playlistScottyEncryptedBlobId": blobId
                ]
            ]]
        )
        guard response["status"] as? String == "STATUS_SUCCEEDED" else {
            throw UploadError.rejected(step: "playlist update")
        }

        let header = ((response["newHeader"] as? [String: Any])?["musicEditablePlaylistDetailHeaderRenderer"]
            as? [String: Any])?["header"] as? [String: Any]
        let newURL = (header?["musicResponsiveHeaderRenderer"] as? [String: Any])
            .flatMap(InnerTubeJSON.musicThumbnailURL)
        if let newURL, var entity = try? await DatabaseService.shared.fetchOne(PlaylistEntity.self, key: playlistId) {
            entity.thumbnailUrl = newURL
            try? await DatabaseService.shared.save(entity)
        }
        return newURL
    }

    /// Center-cropped square JPEG, at most `coverSide` pixels wide.
    private static func squareJPEG(_ image: UIImage) -> Data? {
        let square = image.centerCroppedSquare()
        let side = min(coverSide, square.size.width * square.scale)
        guard side > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            square.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        return resized.jpegData(compressionQuality: 0.85)
    }
}
