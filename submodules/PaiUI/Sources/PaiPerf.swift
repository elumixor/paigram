import Darwin
import Foundation

/// Launch timing: `PAIPERF <name> +<ms since the process started>` in the device log (Console.app, or
/// `log stream --predicate 'eventMessage CONTAINS "PAIPERF"'`).
public enum PaiPerf {
    private static let lock = NSLock()
    private static var seen: Set<String> = []

    /// The process's start time from the kernel, so marks count from exec rather than from the first mark.
    private static let processStart: TimeInterval = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else {
            return Date().timeIntervalSince1970
        }
        let start = info.kp_proc.p_un.__p_starttime
        return TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000
    }()

    /// Milliseconds since the process started.
    public static var elapsed: Int {
        Int((Date().timeIntervalSince1970 - processStart) * 1000)
    }

    /// Logs every time it is reached.
    public static func mark(_ name: String) {
        NSLog("PAIPERF %@ +%dms", name, elapsed)
    }

    /// Logs only the first time a name is reached.
    public static func first(_ name: String) {
        lock.lock()
        let isNew = seen.insert(name).inserted
        lock.unlock()
        if isNew { mark(name) }
    }
}
