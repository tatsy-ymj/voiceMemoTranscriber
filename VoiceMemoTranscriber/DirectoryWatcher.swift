import Foundation
import Darwin

enum DirectoryWatcherError: Error {
    case openFailed
}

final class DirectoryWatcher {
    private let directoryURL: URL
    private var fileDescriptor: CInt = -1
    private var source: DispatchSourceFileSystemObject?
    private let eventHandler: () -> Void

    init(directoryURL: URL, eventHandler: @escaping () -> Void) throws {
        self.directoryURL = directoryURL
        self.eventHandler = eventHandler

        fileDescriptor = open((directoryURL.path as NSString).fileSystemRepresentation, O_EVTONLY)
        if fileDescriptor < 0 {
            throw DirectoryWatcherError.openFailed
        }
    }

    func start() {
        guard source == nil else { return }

        let mask: DispatchSource.FileSystemEvent = [.write, .rename, .delete, .attrib, .extend]
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: mask,
            queue: DispatchQueue.global(qos: .utility)
        )

        src.setEventHandler { [weak self] in
            self?.eventHandler()
        }

        src.setCancelHandler { [fileDescriptor] in
            close(fileDescriptor)
        }

        source = src
        src.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    deinit {
        stop()
    }
}
