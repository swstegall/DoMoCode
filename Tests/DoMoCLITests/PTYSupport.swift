// Copyright (c) 2026 Sam Stegall. MIT license.
// SPDX-License-Identifier: MIT
//
// Opening a pty, on both platforms.

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Open a pty master and return it together with the slave device path, or `nil`
/// if this environment has no pty to give.
///
/// Darwin has `posix_openpt`, `grantpt`, `unlockpt` and `ptsname`. Swift's Glibc
/// module exports NONE of them — they are `_XOPEN_SOURCE` declarations its
/// modulemap does not surface, verified against `swift:6.3.3` — so Linux goes the
/// long way round: open `/dev/ptmx` and issue the two ioctls those functions
/// wrap. `TIOCSPTLCK` with zero is what `unlockpt` does; `TIOCGPTN` reports the
/// slave number `ptsname` formats into a path.
///
/// Returning `nil` rather than trapping is deliberate and pre-existing: a
/// sandbox with no `/dev/pts` should SKIP these tests, not fail them.
func openPTYMaster() -> (master: Int32, slaveName: String)? {
    #if canImport(Darwin)
    let master = posix_openpt(O_RDWR | O_NOCTTY)
    guard master >= 0 else { return nil }
    guard grantpt(master) == 0, unlockpt(master) == 0, let name = ptsname(master) else {
        _ = close(master)
        return nil
    }
    return (master, String(cString: name))
    #else
    let master = open("/dev/ptmx", O_RDWR | O_NOCTTY)
    guard master >= 0 else { return nil }
    var unlock: Int32 = 0
    guard ioctl(master, UInt(0x4004_5431), &unlock) == 0 else {  // TIOCSPTLCK
        _ = close(master)
        return nil
    }
    var number: Int32 = 0
    guard ioctl(master, UInt(0x8004_5430), &number) == 0 else {  // TIOCGPTN
        _ = close(master)
        return nil
    }
    return (master, "/dev/pts/\(number)")
    #endif
}
