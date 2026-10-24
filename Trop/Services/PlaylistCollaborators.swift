//
//  PlaylistCollaborators.swift
//  Trop
//

import Foundation

struct PlaylistCollaborator: Hashable {
    var name: String
    var avatarUrl: String?
    var isOwner: Bool
}

enum PlaylistCollaborators {
    /// The people on a shared playlist, owner first. `params` comes from the
    /// playlist header's facepile; an empty list means the request failed.
    static func fetch(params: String) async -> [PlaylistCollaborator] {
        guard let data = try? await SignedInnerTube.post("get_panel", ["panelId": "PAplaylist_collaborate", "params": params]),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let people = (((((json["content"] as? [String: Any])?["engagementPanelSectionListRenderer"] as? [String: Any])?["content"]
            as? [String: Any])?["playlistCollaborationViewModel"] as? [String: Any])?["playlistCollaborators"] as? [[String: Any]]) ?? []
        return people.enumerated().compactMap { index, person in
            guard let item = person["contentListItemViewModel"] as? [String: Any],
                  let name = (item["title"] as? [String: Any])?["content"] as? String else { return nil }
            let url = ((((item["avatar"] as? [String: Any])?["avatarViewModel"] as? [String: Any])?["image"] as? [String: Any])?["sources"]
                as? [[String: Any]])?.first?["url"] as? String
            // YouTube lists the owner first.
            return PlaylistCollaborator(name: name, avatarUrl: url, isOwner: index == 0)
        }
    }
}
