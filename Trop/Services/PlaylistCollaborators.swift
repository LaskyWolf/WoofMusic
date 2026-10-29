//
//  PlaylistCollaborators.swift
//  Trop
//

import Foundation

struct PlaylistCollaborator: Hashable {
    var name: String
    var avatarUrl: String?
    var isOwner: Bool
    /// The person's channel, for their profile page; nil when the list has no link.
    var channelId: String?
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
            return PlaylistCollaborator(name: name, avatarUrl: url, isOwner: index == 0, channelId: channelId(in: item))
        }
    }

    /// The first channel id (UC…) anywhere under `value`: the row's tap command.
    private static func channelId(in value: Any) -> String? {
        if let dict = value as? [String: Any] {
            if let id = dict["browseId"] as? String, id.hasPrefix("UC") { return id }
            return dict.values.lazy.compactMap { channelId(in: $0) }.first
        }
        if let array = value as? [Any] {
            return array.lazy.compactMap { channelId(in: $0) }.first
        }
        return nil
    }
}
