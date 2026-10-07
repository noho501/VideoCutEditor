import Foundation

public enum VideoCutFileManager {
    public enum FileError: LocalizedError {
        case URLOutsideVideoCutEditorDirectory

        public var errorDescription: String? {
            "The URL is outside the VideoCutEditor temporary directory."
        }
    }

    public static var baseDirectoryURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoCutEditor", isDirectory: true)
            .standardizedFileURL
    }

    public static func makeOutputURL() throws -> URL {
        try FileManager.default.createDirectory(
            at: baseDirectoryURL,
            withIntermediateDirectories: true
        )
        return baseDirectoryURL.appendingPathComponent("\(UUID().uuidString).mp4")
    }

    @discardableResult
    public static func remove(_ url: URL) -> Result<Void, Error> {
        do {
            guard isManagedURL(url) else {
                throw FileError.URLOutsideVideoCutEditorDirectory
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                return .success(())
            }
            try FileManager.default.removeItem(at: url)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    @discardableResult
    public static func clearTemporaryFiles() -> Result<Void, Error> {
        do {
            let directory = baseDirectoryURL
            guard FileManager.default.fileExists(atPath: directory.path) else {
                return .success(())
            }
            try FileManager.default.removeItem(at: directory)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    private static func isManagedURL(_ url: URL) -> Bool {
        let basePath = baseDirectoryURL.path
        let candidatePath = url.standardizedFileURL.path
        return candidatePath == basePath || candidatePath.hasPrefix(basePath + "/")
    }
}
