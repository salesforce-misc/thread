/*
 * Copyright (c) 2026, Salesforce, Inc.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import Foundation
import SQLite3
import Compression
import Security

/// One task to mark on the note Thread just copied.
struct NotesChecklistItem: Sendable {
    var text: String
    var done: Bool
}

enum NotesChecklistError: LocalizedError {
    case fullDiskAccess
    case noteMissing
    case tasksNotFound([String])
    case corruptNote
    case database(String)

    var errorDescription: String? {
        switch self {
        case .fullDiskAccess:
            return "The note was copied, but tasks could not become checkboxes. Turn on Full Disk Access for Thread in System Settings › Privacy & Security › Full Disk Access, then copy the session again."
        case .noteMissing:
            return "The note was copied, but Thread could not find it in the Notes database to add checkboxes."
        case .tasksNotFound(let missing):
            return "The note was copied, but these tasks did not match lines in the note: \(missing.joined(separator: ", "))."
        case .corruptNote:
            return "The note was copied, but its Notes data could not be read for checkboxes."
        case .database(let message):
            return "The note was copied, but the Notes database could not be updated (\(message))."
        }
    }
}

/// After AppleScript writes the note text, mark the task lines as native
/// Notes checkboxes. The words stay as Notes wrote them.
enum NotesChecklistPatch {
    private static let databasePath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/group.com.apple.notes/NoteStore.sqlite")
        .path

    static func apply(noteID: String, items: [NotesChecklistItem]) -> Result<Int, Error> {
        do {
            return .success(try write(noteID: noteID, items: items))
        } catch {
            return .failure(error)
        }
    }

    private static func write(noteID: String, items: [NotesChecklistItem]) throws -> Int {
        let wanted = items.filter { !normalize($0.text).isEmpty }
        guard !wanted.isEmpty else { return 0 }
        guard let primaryKey = primaryKey(from: noteID) else {
            throw NotesChecklistError.noteMissing
        }
        guard FileManager.default.isReadableFile(atPath: databasePath) else {
            throw NotesChecklistError.fullDiskAccess
        }

        var db: OpaquePointer?
        let opened = sqlite3_open_v2(databasePath, &db, SQLITE_OPEN_READWRITE, nil)
        guard opened == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open"
            sqlite3_close(db)
            if opened == SQLITE_CANTOPEN || opened == SQLITE_AUTH
                || message.localizedCaseInsensitiveContains("authoriz") {
                throw NotesChecklistError.fullDiskAccess
            }
            throw NotesChecklistError.database(message)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 8000)

        let row = try loadNote(db, primaryKey: primaryKey)
        let protobuf = try gunzip(row.data)
        let (updated, marked, inProgress) = try transform(protobuf, tasks: wanted)
        let stored = gzip(updated)
        try writeNote(db, noteKey: primaryKey, dataKey: row.dataKey, blob: stored, inProgress: inProgress)
        if marked.count != wanted.count {
            let found = Set(marked)
            let missing = wanted.map { normalize($0.text) }.filter { !found.contains($0) }
            throw NotesChecklistError.tasksNotFound(missing)
        }
        return marked.count
    }

    /// Returns the rewritten protobuf, the normalized task lines that were
    /// marked, and whether any marked task is still open.
    static func transform(_ protobuf: Data, tasks: [NotesChecklistItem]) throws -> (Data, [String], Bool) {
        var top = try parse(protobuf)
        guard let docIndex = top.firstIndex(where: { $0.number == 2 && $0.isBytes }) else {
            throw NotesChecklistError.corruptNote
        }
        var document = try parse(top[docIndex].bytes)
        guard let noteIndex = document.firstIndex(where: { $0.number == 3 && $0.isBytes }) else {
            throw NotesChecklistError.corruptNote
        }
        let note = try parse(document[noteIndex].bytes)
        guard let textField = note.first(where: { $0.number == 2 && $0.isBytes }),
              let text = String(data: textField.bytes, encoding: .utf8) else {
            throw NotesChecklistError.corruptNote
        }
        let scalars = Array(text.unicodeScalars)
        var runs = try attributeRuns(in: note, scalarCount: scalars.count)
        splitAtNewlines(&runs, scalars: scalars)
        let lines = linesIn(scalars)
        let (marked, inProgress) = markTasks(&runs, lines: lines, tasks: tasks)
        guard !marked.isEmpty else {
            let missing = tasks.map { normalize($0.text) }.filter { !$0.isEmpty }
            throw NotesChecklistError.tasksNotFound(missing)
        }

        var rewritten: [ProtoField] = []
        var inserted = false
        for field in note {
            if field.number == 5 {
                if !inserted {
                    rewritten.append(contentsOf: emitRuns(runs))
                    inserted = true
                }
                continue
            }
            rewritten.append(field)
        }
        if !inserted {
            rewritten.append(contentsOf: emitRuns(runs))
        }
        document[noteIndex].bytes = emit(rewritten)
        top[docIndex].bytes = emit(document)
        return (emit(top), marked, inProgress)
    }

    // MARK: - Note rows

    private struct NoteRow {
        var dataKey: Int64
        var data: Data
    }

    private static func loadNote(_ db: OpaquePointer, primaryKey: Int64) throws -> NoteRow {
        let sql = """
        SELECT d.Z_PK, d.ZDATA
        FROM ZICCLOUDSYNCINGOBJECT n
        JOIN ZICNOTEDATA d ON d.Z_PK = n.ZNOTEDATA
        WHERE n.Z_PK = ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NotesChecklistError.database(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, primaryKey)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw NotesChecklistError.noteMissing
        }
        let dataKey = sqlite3_column_int64(statement, 0)
        guard let pointer = sqlite3_column_blob(statement, 1) else {
            throw NotesChecklistError.corruptNote
        }
        let count = Int(sqlite3_column_bytes(statement, 1))
        return NoteRow(dataKey: dataKey, data: Data(bytes: pointer, count: count))
    }

    private static func writeNote(_ db: OpaquePointer, noteKey: Int64, dataKey: Int64,
                                  blob: Data, inProgress: Bool) throws {
        let destructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let updateData = "UPDATE ZICNOTEDATA SET ZDATA = ?, Z_OPT = IFNULL(Z_OPT, 0) + 1 WHERE Z_PK = ?"
        var dataStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, updateData, -1, &dataStatement, nil) == SQLITE_OK else {
            throw NotesChecklistError.database(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(dataStatement) }
        let bound = blob.withUnsafeBytes { raw -> Int32 in
            sqlite3_bind_blob(dataStatement, 1, raw.baseAddress, Int32(blob.count), destructor)
        }
        guard bound == SQLITE_OK else {
            throw NotesChecklistError.database(String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_int64(dataStatement, 2, dataKey)
        guard sqlite3_step(dataStatement) == SQLITE_DONE else {
            throw NotesChecklistError.database(String(cString: sqlite3_errmsg(db)))
        }

        let updateNote = """
        UPDATE ZICCLOUDSYNCINGOBJECT
        SET ZHASCHECKLIST = 1, ZHASCHECKLISTINPROGRESS = ?, ZMODIFICATIONDATE = ?,
            Z_OPT = IFNULL(Z_OPT, 0) + 1
        WHERE Z_PK = ?
        """
        var noteStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, updateNote, -1, &noteStatement, nil) == SQLITE_OK else {
            throw NotesChecklistError.database(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(noteStatement) }
        sqlite3_bind_int(noteStatement, 1, inProgress ? 1 : 0)
        sqlite3_bind_double(noteStatement, 2, Date().timeIntervalSinceReferenceDate)
        sqlite3_bind_int64(noteStatement, 3, noteKey)
        guard sqlite3_step(noteStatement) == SQLITE_DONE else {
            throw NotesChecklistError.database(String(cString: sqlite3_errmsg(db)))
        }
    }

    private static func primaryKey(from noteID: String) -> Int64? {
        guard let range = noteID.range(of: "/ICNote/p") else { return nil }
        let digits = noteID[range.upperBound...].prefix { $0.isNumber }
        return Int64(digits)
    }

    // MARK: - Checklist marking

    private struct Run {
        var start: Int
        var length: Int
        var style: [ProtoField]
        var extras: [ProtoField]
        var checklist: (uuid: Data, done: Bool)?
    }

    private struct Line {
        var start: Int
        var end: Int
        var text: String
    }

    private static func attributeRuns(in note: [ProtoField], scalarCount: Int) throws -> [Run] {
        var runs: [Run] = []
        var cursor = 0
        for field in note where field.number == 5 && field.isBytes {
            let parts = try parse(field.bytes)
            guard let lengthField = parts.first(where: { $0.number == 1 && $0.wire == 0 }) else {
                throw NotesChecklistError.corruptNote
            }
            let length = Int(lengthField.varint)
            let style = parts.first(where: { $0.number == 2 && $0.isBytes }).map { (try? parse($0.bytes)) ?? [] } ?? []
            let extras = parts.filter { $0.number != 1 && $0.number != 2 }
            runs.append(Run(start: cursor, length: length, style: style, extras: extras, checklist: nil))
            cursor += length
        }
        guard cursor == scalarCount else { throw NotesChecklistError.corruptNote }
        return runs
    }

    private static func splitAtNewlines(_ runs: inout [Run], scalars: [Unicode.Scalar]) {
        let newline = Unicode.Scalar(10)!
        var index = 0
        while index < runs.count {
            let run = runs[index]
            let end = run.start + run.length
            guard run.length > 1,
                  let newlineAt = scalars[run.start..<end].firstIndex(of: newline) else {
                index += 1
                continue
            }
            let split = newlineAt + 1
            guard split < end else {
                index += 1
                continue
            }
            var right = run
            right.start = split
            right.length = end - split
            runs[index].length = split - run.start
            runs.insert(right, at: index + 1)
            index += 1
        }
    }

    private static func linesIn(_ scalars: [Unicode.Scalar]) -> [Line] {
        let newline = Unicode.Scalar(10)!
        var lines: [Line] = []
        var start = 0
        var index = 0
        while index < scalars.count {
            if scalars[index] == newline {
                let text = String(String.UnicodeScalarView(scalars[start..<index]))
                lines.append(Line(start: start, end: index + 1, text: text))
                start = index + 1
            }
            index += 1
        }
        if start < scalars.count {
            let text = String(String.UnicodeScalarView(scalars[start..<scalars.count]))
            lines.append(Line(start: start, end: scalars.count, text: text))
        }
        return lines
    }

    private static func markTasks(_ runs: inout [Run], lines: [Line],
                                  tasks: [NotesChecklistItem]) -> ([String], Bool) {
        var pending = tasks.map { (normalize($0.text), $0.done) }.filter { !$0.0.isEmpty }
        var marked: [String] = []
        var inProgress = false
        var inTasks = false
        for line in lines {
            let key = normalize(line.text)
            if key == "Transcript" { break }
            if key == "Tasks" {
                inTasks = true
                continue
            }
            guard inTasks, !key.isEmpty,
                  let match = pending.firstIndex(where: { $0.0 == key }) else { continue }
            let done = pending[match].1
            pending.remove(at: match)
            if !done { inProgress = true }
            let uuid = randomBytes(16)
            for index in runs.indices {
                let run = runs[index]
                let runEnd = run.start + run.length
                guard run.start >= line.start, runEnd <= line.end, run.length > 0 else { continue }
                runs[index].checklist = (uuid, done)
            }
            marked.append(key)
        }
        return (marked, inProgress)
    }

    private static func emitRuns(_ runs: [Run]) -> [ProtoField] {
        runs.map { run in
            var fields: [ProtoField] = [.varint(1, UInt64(run.length))]
            var style = run.style.filter { $0.number != 1 && $0.number != 5 }
            if let checklist = run.checklist {
                var styled: [ProtoField] = [.varint(1, 103)]
                if !style.contains(where: { $0.number == 3 }) {
                    styled.append(.varint(3, 1))
                }
                styled.append(contentsOf: style)
                let body = emit([
                    .bytes(1, checklist.uuid),
                    .varint(2, checklist.done ? 1 : 0)
                ])
                styled.append(.bytes(5, body))
                if !styled.contains(where: { $0.number == 9 }) {
                    styled.append(.bytes(9, Data(UUID().uuidString
                        .replacingOccurrences(of: "-", with: "")
                        .lowercased()
                        .utf8)))
                }
                style = styled
            }
            if !style.isEmpty {
                fields.append(.bytes(2, emit(style)))
            }
            fields.append(contentsOf: run.extras)
            return .bytes(5, emit(fields))
        }
    }

    private static func normalize(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["☐ ", "☑︎ ", "☑ ", "☐", "☑︎", "☑"]
        for prefix in prefixes where value.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        return value
    }

    private static func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { buffer in
            guard let address = buffer.baseAddress else { return }
            _ = SecRandomCopyBytes(kSecRandomDefault, count, address)
        }
        return data
    }

    // MARK: - Gzip

    private static func gunzip(_ data: Data) throws -> Data {
        guard data.count > 18, data[0] == 0x1f, data[1] == 0x8b, data[2] == 0x08 else {
            throw NotesChecklistError.corruptNote
        }
        let flags = data[3]
        var offset = 10
        if flags & 0x04 != 0 {
            guard offset + 2 <= data.count else { throw NotesChecklistError.corruptNote }
            let extra = Int(data[offset]) | (Int(data[offset + 1]) << 8)
            offset += 2 + extra
        }
        if flags & 0x08 != 0 {
            offset = try skipZero(data, offset)
        }
        if flags & 0x10 != 0 {
            offset = try skipZero(data, offset)
        }
        if flags & 0x02 != 0 { offset += 2 }
        guard offset < data.count - 8 else { throw NotesChecklistError.corruptNote }
        let trailer = Array(data.suffix(4))
        let expected = Int(UInt32(trailer[0])
                           | (UInt32(trailer[1]) << 8)
                           | (UInt32(trailer[2]) << 16)
                           | (UInt32(trailer[3]) << 24))
        let deflate = data.subdata(in: offset..<(data.count - 8))
        let inflated = try inflate(deflate, expected: expected)
        guard expected == 0 || inflated.count == expected else {
            throw NotesChecklistError.corruptNote
        }
        return inflated
    }

    private static func skipZero(_ data: Data, _ start: Int) throws -> Int {
        var index = start
        while index < data.count {
            if data[index] == 0 { return index + 1 }
            index += 1
        }
        throw NotesChecklistError.corruptNote
    }

    private static func inflate(_ data: Data, expected: Int) throws -> Data {
        let capacity = max(expected, 64)
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { destination.deallocate() }
        let written = data.withUnsafeBytes { raw -> Int in
            guard let source = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(destination, capacity, source, data.count, nil, COMPRESSION_ZLIB)
        }
        guard written == capacity || (expected == 0 && written > 0) else {
            throw NotesChecklistError.corruptNote
        }
        return Data(bytes: destination, count: written)
    }

    private static func gzip(_ data: Data) -> Data {
        let bound = data.count + data.count / 16 + 64
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: max(bound, 64))
        defer { destination.deallocate() }
        let written = data.withUnsafeBytes { raw -> Int in
            guard let source = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(destination, max(bound, 64), source, data.count, nil, COMPRESSION_ZLIB)
        }
        var output = Data([0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        if written > 0 {
            output.append(destination, count: written)
        }
        var crc = checksum(data).littleEndian
        var size = UInt32(truncatingIfNeeded: data.count).littleEndian
        withUnsafeBytes(of: &crc) { output.append(contentsOf: $0) }
        withUnsafeBytes(of: &size) { output.append(contentsOf: $0) }
        return output
    }

    private static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            var value = (crc ^ UInt32(byte)) & 0xff
            for _ in 0..<8 {
                value = (value & 1) == 1 ? (0xedb8_8320 ^ (value >> 1)) : (value >> 1)
            }
            crc = (crc >> 8) ^ value
        }
        return crc ^ 0xffff_ffff
    }

    // MARK: - Protobuf

    private struct ProtoField {
        var number: Int
        var wire: Int
        var varint: UInt64 = 0
        var bytes: Data = Data()

        var isBytes: Bool { wire == 2 }

        static func varint(_ number: Int, _ value: UInt64) -> ProtoField {
            ProtoField(number: number, wire: 0, varint: value)
        }

        static func bytes(_ number: Int, _ value: Data) -> ProtoField {
            ProtoField(number: number, wire: 2, bytes: value)
        }
    }

    private static func parse(_ data: Data) throws -> [ProtoField] {
        var fields: [ProtoField] = []
        var index = 0
        let bytes = [UInt8](data)
        while index < bytes.count {
            let key = try readVarint(bytes, &index)
            let number = Int(key >> 3)
            let wire = Int(key & 7)
            switch wire {
            case 0:
                let value = try readVarint(bytes, &index)
                fields.append(ProtoField(number: number, wire: 0, varint: value))
            case 2:
                let length = Int(try readVarint(bytes, &index))
                guard index + length <= bytes.count else { throw NotesChecklistError.corruptNote }
                fields.append(ProtoField(number: number, wire: 2, bytes: Data(bytes[index..<(index + length)])))
                index += length
            case 5:
                guard index + 4 <= bytes.count else { throw NotesChecklistError.corruptNote }
                fields.append(ProtoField(number: number, wire: 5, bytes: Data(bytes[index..<(index + 4)])))
                index += 4
            case 1:
                guard index + 8 <= bytes.count else { throw NotesChecklistError.corruptNote }
                fields.append(ProtoField(number: number, wire: 1, bytes: Data(bytes[index..<(index + 8)])))
                index += 8
            default:
                throw NotesChecklistError.corruptNote
            }
        }
        return fields
    }

    private static func emit(_ fields: [ProtoField]) -> Data {
        var output = Data()
        for field in fields {
            output.append(contentsOf: writeVarint(UInt64((field.number << 3) | field.wire)))
            switch field.wire {
            case 0:
                output.append(contentsOf: writeVarint(field.varint))
            case 2:
                output.append(contentsOf: writeVarint(UInt64(field.bytes.count)))
                output.append(field.bytes)
            case 5, 1:
                output.append(field.bytes)
            default:
                break
            }
        }
        return output
    }

    private static func readVarint(_ bytes: [UInt8], _ index: inout Int) throws -> UInt64 {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            value |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
            if shift > 63 { throw NotesChecklistError.corruptNote }
        }
        throw NotesChecklistError.corruptNote
    }

    private static func writeVarint(_ value: UInt64) -> [UInt8] {
        var rest = value
        var bytes: [UInt8] = []
        while true {
            let piece = UInt8(rest & 0x7f)
            rest >>= 7
            if rest == 0 {
                bytes.append(piece)
                return bytes
            }
            bytes.append(piece | 0x80)
        }
    }
}
