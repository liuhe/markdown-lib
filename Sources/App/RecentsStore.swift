import Foundation

/// Persisted list of recently opened files and workspaces. Stored in
/// UserDefaults as arrays of absolute path strings. Two separate lists so we
/// can cap them independently (files churn faster than folders).
final class RecentsStore {

    static let shared = RecentsStore()
    private init() {}

    private let filesKey = "RecentFiles"
    private let foldersKey = "RecentFolders"

    let maxFiles = 20
    let maxFolders = 15

    // MARK: - Read

    var files: [URL]   { load(filesKey) }
    var folders: [URL] { load(foldersKey) }

    // MARK: - Write

    func addFile(_ url: URL)   { add(url, key: filesKey,   max: maxFiles) }
    func addFolder(_ url: URL) { add(url, key: foldersKey, max: maxFolders) }

    func remove(_ url: URL) {
        for key in [filesKey, foldersKey] {
            var list = load(key)
            list.removeAll { $0 == url }
            save(list, key: key)
        }
    }

    func clearFiles()   { UserDefaults.standard.removeObject(forKey: filesKey) }
    func clearFolders() { UserDefaults.standard.removeObject(forKey: foldersKey) }

    func clearAll() { clearFiles(); clearFolders() }

    // MARK: - Storage

    private func add(_ url: URL, key: String, max: Int) {
        let canonical = url.standardizedFileURL
        var list = load(key)
        list.removeAll { $0 == canonical }
        list.insert(canonical, at: 0)
        if list.count > max { list = Array(list.prefix(max)) }
        save(list, key: key)
    }

    private func load(_ key: String) -> [URL] {
        let paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        return paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
    }

    private func save(_ urls: [URL], key: String) {
        UserDefaults.standard.set(urls.map { $0.path }, forKey: key)
    }
}
