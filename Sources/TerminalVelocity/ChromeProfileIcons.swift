import AppKit

struct ChromeProfileIcon {
    let name: String
    let image: NSImage

    static func matching(_ label: String?, profiles: [ChromeProfileIcon]) -> NSImage? {
        guard let label else { return nil }
        let matches = profiles.filter { label == $0.name || label.hasSuffix("(" + $0.name + ")") }
        return matches.count == 1 ? matches[0].image : nil
    }
    static func load() -> [ChromeProfileIcon] {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Google/Chrome")
        guard let data = try? Data(contentsOf: root.appendingPathComponent("Local State")), data.count < 5_000_000,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = json["profile"] as? [String: Any], let cache = profile["info_cache"] as? [String: [String: Any]] else { return [] }
        return cache.compactMap { directory, value in
            guard directory == (directory as NSString).lastPathComponent,
                  let name = value["name"] as? String, !name.isEmpty else { return nil }
            if value["is_using_default_avatar"] as? Bool != false,
               let file = value["gaia_picture_file_name"] as? String,
               file == (file as NSString).lastPathComponent,
               let image = NSImage(contentsOf: root.appendingPathComponent(directory).appendingPathComponent(file)) {
                return ChromeProfileIcon(name: name, image: image)
            }
            return nil
        }
    }
}
