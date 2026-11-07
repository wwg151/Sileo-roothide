//
//  PackageRepacker.swift
//  Sileo
//
//  Rebuilds an installed package into a .deb from the files dpkg recorded.
//

import Darwin
import Foundation

final class PackageRepacker {

    enum RepackError: LocalizedError {
        case noFileList
        case noFiles
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .noFileList:
                return String(localizationKey: "Backup_No_File_List", type: .error)
            case .noFiles:
                return String(localizationKey: "Backup_No_Files", type: .error)
            case .commandFailed(let output):
                return output
            }
        }
    }

    static var tarPath: String {
        let candidates = ["\(CommandPath.prefix)/usr/bin/tar", "\(CommandPath.prefix)/bin/tar"]
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate) {
            return candidate
        }
        return candidates[0]
    }

    /// dpkg's database, either where procursus keeps it or the classic path.
    static var databaseDirectory: URL {
        let library = URL(fileURLWithPath: "\(CommandPath.prefix)/Library/dpkg", isDirectory: true)
        if FileManager.default.fileExists(atPath: library.path) {
            return library
        }
        return URL(fileURLWithPath: "\(CommandPath.prefix)/var/lib/dpkg", isDirectory: true)
    }

    /// Rebuilds `package` into a .deb written at `destination`.
    static func repack(package: Package, to destination: URL) throws -> URL {
        let fileManager = FileManager.default
        let work = fileManager.temporaryDirectory
            .appendingPathComponent("sileo-repack-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        defer {
            spawnAsRoot(args: [CommandPath.rm, "-rf", rootfs(work.path)])
        }

        let controlDirectory = work.appendingPathComponent("DEBIAN", isDirectory: true)
        try fileManager.createDirectory(at: controlDirectory, withIntermediateDirectories: true)
        try writeControl(package: package, to: controlDirectory)

        let paths = try recordedPaths(package: package)
        guard !paths.isEmpty else { throw RepackError.noFiles }

        let payload = work.appendingPathComponent("payload", isDirectory: true)
        try fileManager.createDirectory(at: payload, withIntermediateDirectories: true)
        try copyPayload(paths: paths, to: payload, in: work)
        spawnAsRoot(args: [
            CommandPath.cp, "-a",
            rootfs(controlDirectory.path),
            rootfs(payload.appendingPathComponent("DEBIAN").path)
        ])

        try? fileManager.removeItem(at: destination)
        let (status, _, errorOutput) = spawnAsRoot(args: [
            CommandPath.dpkgdeb, "-b", "-Zxz",
            rootfs(payload.path), rootfs(destination.path)
        ])
        guard status == 0 else {
            throw RepackError.commandFailed(errorOutput.isEmpty ? "dpkg-deb exited with \(status)" : errorOutput)
        }
        spawnAsRoot(args: [CommandPath.chown, "501:501", rootfs(destination.path)])
        return destination
    }

    // MARK: - Control

    private static func writeControl(package: Package, to directory: URL) throws {
        let (status, output, errorOutput) = spawnAsRoot(args: [CommandPath.dpkg, "-s", package.package])
        guard status == 0 else {
            throw RepackError.commandFailed(errorOutput.isEmpty ? output : errorOutput)
        }

        var lines: [String] = []
        for line in output.components(separatedBy: "\n") {
            let lowered = line.lowercased()
            if lowered.hasPrefix("status:") || lowered.hasPrefix("conffiles:")
                || lowered.hasPrefix("config-version:") || lowered.hasPrefix("triggers-pending:")
                || lowered.hasPrefix("triggers-awaited:") {
                continue
            }
            lines.append(line)
        }
        var text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = text.lowercased()
        if !lowered.contains("maintainer:") {
            text += "\nMaintainer: unknown <unknown@localhost>"
        }
        if !lowered.contains("description:") {
            text += "\nDescription: Repacked from the installed package"
        }
        try (text + "\n").write(
            to: directory.appendingPathComponent("control"),
            atomically: true,
            encoding: .utf8
        )

        // The maintainer scripts and other members dpkg kept beside the list.
        let info = databaseDirectory.appendingPathComponent("info", isDirectory: true)
        guard let members = try? FileManager.default.contentsOfDirectory(atPath: info.path) else {
            return
        }
        let prefix = "\(package.package)."
        for member in members where member.hasPrefix(prefix) {
            let name = String(member.dropFirst(prefix.count))
            if name == "list" || name == "md5sums" || name == "status" {
                continue
            }
            spawnAsRoot(args: [
                CommandPath.cp, "-a",
                rootfs(info.appendingPathComponent(member).path),
                rootfs(directory.appendingPathComponent(name).path)
            ])
        }
    }

    // MARK: - Payload

    private static func recordedPaths(package: Package) throws -> [String] {
        let listURL = databaseDirectory
            .appendingPathComponent("info", isDirectory: true)
            .appendingPathComponent("\(package.package).list")
        guard let text = try? String(contentsOf: listURL, encoding: .utf8) else {
            throw RepackError.noFileList
        }
        var paths: [String] = []
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("/"), trimmed != "/." else { continue }
            paths.append(trimmed)
        }
        return paths
    }

    private static func copyPayload(paths: [String], to payload: URL, in work: URL) throws {
        var relativePaths: [String] = []
        for path in paths {
            let relative = String(path.dropFirst())
            guard !relative.isEmpty else { continue }
            var info = stat()
            guard lstat("\(CommandPath.prefix)/\(relative)", &info) == 0 else { continue }
            relativePaths.append(relative)
        }
        guard !relativePaths.isEmpty else { throw RepackError.noFiles }

        // Every path that has something listed below it.
        var parents = Set<String>()
        for relative in relativePaths {
            var parts = relative.split(separator: "/").map(String.init)
            while parts.count > 1 {
                parts.removeLast()
                parents.insert(parts.joined(separator: "/"))
            }
        }

        // The bootstrap keeps some directories as links (ElleKit's
        // DynamicLibraries, the jbroot's var): written as a link, nothing can
        // be put below it, so those go in as directories.
        var archived: [String] = []
        var materialised: [String] = []
        for relative in relativePaths {
            var info = stat()
            guard lstat("\(CommandPath.prefix)/\(relative)", &info) == 0 else { continue }
            if info.st_mode & S_IFMT == S_IFLNK, parents.contains(relative) {
                materialised.append(relative)
            } else {
                archived.append(relative)
            }
        }

        for relative in materialised.sorted(by: { $0.count < $1.count }) {
            let target = payload.appendingPathComponent(relative).path
            spawnAsRoot(args: [CommandPath.mkdir, "-p", rootfs(target)])
            spawnAsRoot(args: [CommandPath.chown, "0:0", rootfs(target)])
            spawnAsRoot(args: [CommandPath.chmod, "0755", rootfs(target)])
        }

        let listURL = work.appendingPathComponent("paths.txt")
        try (archived.joined(separator: "\n") + "\n").write(to: listURL, atomically: true, encoding: .utf8)
        let archive = work.appendingPathComponent("payload.tar")

        let (createStatus, _, createError) = spawnAsRoot(args: [
            tarPath, "-cf", rootfs(archive.path),
            "-C", rootfs(CommandPath.prefix),
            "--no-recursion", "--ignore-failed-read", "-T", rootfs(listURL.path)
        ])
        guard createStatus == 0 else {
            throw RepackError.commandFailed(createError)
        }

        let (extractStatus, _, extractError) = spawnAsRoot(args: [
            tarPath, "-xpf", rootfs(archive.path), "-C", rootfs(payload.path)
        ])
        guard extractStatus == 0 else {
            throw RepackError.commandFailed(extractError)
        }
    }
}
