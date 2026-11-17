import Foundation

/// AVAudioFile 每写一个 m4a 都会在 moov 后面预留一块约 23 KB 的 `free` 原子，
/// 用来给采样表留出后续增长的空间。对「整天不断切段」的场景这是纯浪费：
/// 一段 4.7 秒的录音真实音频只有 10 KB，容器却是 35 KB。
///
/// 这里在文件关闭后把 `free` 摘掉，并把 moov 里 stco/co64 的采样偏移整体左移。
/// 只处理「free 位于 mdat 之前」这一种布局——正是 AVAudioFile 的固定写法，
/// 其它布局一律原样保留，宁可不省这点空间也不冒损坏文件的风险。
enum MP4Compactor {

    struct Atom {
        let type: String
        let offset: Int
        let size: Int
    }

    /// 返回节省的字节数；0 表示未处理（布局不符合预期或本身已经没有可摘的块）
    @discardableResult
    static func compact(url: URL) -> Int {
        guard let data = try? Data(contentsOf: url), data.count > 8 else { return 0 }

        let topLevel = atoms(in: data, from: 0, to: data.count)
        guard let mdat = topLevel.first(where: { $0.type == "mdat" }),
              let moov = topLevel.first(where: { $0.type == "moov" }) else { return 0 }

        // 只摘 mdat 之前的 free，且 moov 必须在 free 之前（否则 moov 自身位置会变）
        let freeAtoms = topLevel.filter {
            $0.type == "free" && $0.offset < mdat.offset && $0.offset > moov.offset
        }
        guard !freeAtoms.isEmpty else { return 0 }

        let removed = freeAtoms.reduce(0) { $0 + $1.size }
        let firstRemovedOffset = freeAtoms.map(\.offset).min() ?? mdat.offset

        var patched = data
        guard shiftChunkOffsets(in: &patched, moov: moov, threshold: firstRemovedOffset, delta: -removed) else {
            return 0
        }

        // 从后往前删，避免前面的删除让后面的区间失效
        for atom in freeAtoms.sorted(by: { $0.offset > $1.offset }) {
            patched.removeSubrange(atom.offset..<(atom.offset + atom.size))
        }

        guard patched.count == data.count - removed,
              (try? patched.write(to: url, options: .atomic)) != nil else { return 0 }
        return removed
    }

    // MARK: - 解析

    private static func atoms(in data: Data, from start: Int, to end: Int) -> [Atom] {
        var result: [Atom] = []
        var offset = start
        while offset + 8 <= end {
            let size = Int(be32(data, offset))
            let type = fourCC(data, offset + 4)
            let atomSize = size == 0 ? end - offset : size
            guard atomSize >= 8, offset + atomSize <= end else { break }
            result.append(Atom(type: type, offset: offset, size: atomSize))
            offset += atomSize
        }
        return result
    }

    /// 递归查找 stco / co64，把其中指向被删区间的偏移左移。
    /// 全部检查通过才写入，任何一个越界都整体放弃。
    private static func shiftChunkOffsets(
        in data: inout Data,
        moov: Atom,
        threshold: Int,
        delta: Int
    ) -> Bool {
        var entries: [(offset: Int, is64: Bool)] = []
        collectOffsetTables(in: data, from: moov.offset + 8, to: moov.offset + moov.size, into: &entries)
        guard !entries.isEmpty else { return false }

        for entry in entries {
            // stco/co64 布局：size(4) type(4) version+flags(4) entry_count(4) entries…
            let countOffset = entry.offset + 12
            guard countOffset + 4 <= data.count else { return false }
            let count = Int(be32(data, countOffset))
            let entrySize = entry.is64 ? 8 : 4
            let tableStart = countOffset + 4
            guard count > 0, tableStart + count * entrySize <= data.count else { return false }

            for index in 0..<count {
                let position = tableStart + index * entrySize
                let value = entry.is64 ? Int(be64(data, position)) : Int(be32(data, position))
                guard value >= threshold else { continue }
                let updated = value + delta
                guard updated > 0 else { return false }
                if entry.is64 {
                    writeBE64(&data, position, UInt64(updated))
                } else {
                    writeBE32(&data, position, UInt32(updated))
                }
            }
        }
        return true
    }

    private static let containerTypes: Set<String> = [
        "moov", "trak", "mdia", "minf", "stbl", "edts", "udta", "mvex"
    ]

    private static func collectOffsetTables(
        in data: Data,
        from start: Int,
        to end: Int,
        into result: inout [(offset: Int, is64: Bool)]
    ) {
        for atom in atoms(in: data, from: start, to: end) {
            switch atom.type {
            case "stco":
                result.append((atom.offset, false))
            case "co64":
                result.append((atom.offset, true))
            default:
                if containerTypes.contains(atom.type) {
                    collectOffsetTables(in: data, from: atom.offset + 8, to: atom.offset + atom.size, into: &result)
                }
            }
        }
    }

    // MARK: - 字节序

    private static func be32(_ data: Data, _ offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return UInt32(data[base]) << 24 | UInt32(data[base + 1]) << 16
            | UInt32(data[base + 2]) << 8 | UInt32(data[base + 3])
    }

    private static func be64(_ data: Data, _ offset: Int) -> UInt64 {
        UInt64(be32(data, offset)) << 32 | UInt64(be32(data, offset + 4))
    }

    private static func writeBE32(_ data: inout Data, _ offset: Int, _ value: UInt32) {
        let base = data.startIndex + offset
        data[base] = UInt8((value >> 24) & 0xFF)
        data[base + 1] = UInt8((value >> 16) & 0xFF)
        data[base + 2] = UInt8((value >> 8) & 0xFF)
        data[base + 3] = UInt8(value & 0xFF)
    }

    private static func writeBE64(_ data: inout Data, _ offset: Int, _ value: UInt64) {
        writeBE32(&data, offset, UInt32(value >> 32))
        writeBE32(&data, offset + 4, UInt32(value & 0xFFFF_FFFF))
    }

    private static func fourCC(_ data: Data, _ offset: Int) -> String {
        let base = data.startIndex + offset
        guard base + 4 <= data.endIndex else { return "" }
        return String(bytes: data[base..<(base + 4)], encoding: .isoLatin1) ?? ""
    }
}
