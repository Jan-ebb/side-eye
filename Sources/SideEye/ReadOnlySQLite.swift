import Foundation
import SQLite3

/// Opening another app's SQLite database without ever writing to it.
enum ReadOnlySQLite {
    /// The address to open or attach the database at `url` read-only.
    ///
    /// The apps Side Eye reads keep their databases in write-ahead-log mode. An app that closes such a
    /// database cleanly removes its "-wal" and "-shm" files, and SQLite then refuses a read-only open,
    /// because it would have to create them. Codex does this to its turn history whenever it goes quiet.
    /// With no "-wal" file every committed change is in the main file, so the database is read as a file
    /// nobody is changing. Once its app writes again the "-wal" file is back and the ordinary shared read
    /// applies; a read that overlaps that moment is at worst one scan behind.
    static func address(of url: URL) -> String {
        url.absoluteString + (isClosedWriteAheadLog(url) ? "?mode=ro&immutable=1" : "?mode=ro")
    }

    /// A read-only connection, or nil. The caller closes it.
    static func open(_ url: URL) -> OpaquePointer? {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(address(of: url), &database, flags, nil) == SQLITE_OK, let database else {
            sqlite3_close(database)
            return nil
        }
        return database
    }

    private static func isClosedWriteAheadLog(_ url: URL) -> Bool {
        guard !FileManager.default.fileExists(atPath: url.path + "-wal"),
              let file = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? file.close() }
        // Bytes 18 and 19 of the header are the format's write and read versions; 2 is write-ahead log.
        guard let header = try? file.read(upToCount: 20), header.count == 20 else { return false }
        return header[header.startIndex + 18] == 2 || header[header.startIndex + 19] == 2
    }
}
