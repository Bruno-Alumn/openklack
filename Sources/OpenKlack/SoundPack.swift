import Foundation

/// Manifest describing one switch sound set. Lives as `pack.json` inside the
/// pack's folder under Resources/Sounds/<id>/.
struct SoundPackManifest: Codable {
    struct KeySounds: Codable {
        var down: [String]
        var up: [String]?
    }

    var id: String
    var name: String
    var attribution: String?
    var license: String?
    /// Map of KeyClass raw value -> sample files (relative to pack folder).
    /// "default" is required; other classes fall back to it.
    var keys: [String: KeySounds]
    /// Optional master gain trim for this pack, in decibels.
    var gainDb: Float?
}

struct SoundPack: Identifiable {
    let manifest: SoundPackManifest
    let url: URL

    var id: String { manifest.id }
    var name: String { manifest.name }

    /// Resolve the sample list for a key class and stroke direction, falling
    /// back to the default class when the pack has no specific mapping.
    func samples(for keyClass: KeyClass, up: Bool) -> [String] {
        let entry = manifest.keys[keyClass.rawValue] ?? manifest.keys[KeyClass.default.rawValue]
        guard let entry else { return [] }
        if up { return entry.up ?? [] }
        return entry.down
    }

    static func discover(in soundsDir: URL) -> [SoundPack] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: soundsDir,
                                                        includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }
        var packs: [SoundPack] = []
        for dir in entries {
            let manifestURL = dir.appendingPathComponent("pack.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(SoundPackManifest.self, from: data) else {
                continue
            }
            packs.append(SoundPack(manifest: manifest, url: dir))
        }
        return packs.sorted { $0.name < $1.name }
    }
}
