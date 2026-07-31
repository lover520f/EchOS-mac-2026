import Foundation
import Darwin

/// 本地端口不该让用户操心：启动时自动挑一对没被占用的端口。
/// 挑不到就让内核自己报错，不至于静默失败。
enum PortPicker {
    /// 从 start 开始往后找连续两个空闲端口（SOCKS5 用第一个，HTTP 用第二个）
    static func pickPair(from start: Int = 30000, limit: Int = 200) -> (socks: Int, http: Int) {
        var p = start
        let end = min(start + limit, 65534)
        while p < end {
            if isFree(p) && isFree(p + 1) { return (p, p + 1) }
            p += 2
        }
        return (start, start + 1)   // 实在找不到就用默认值，交给内核报错
    }

    /// 用 bind 测试端口是否可用。能 bind 上说明没人在监听。
    static func isFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        // 连 socket 都建不出来，那是本机资源的问题，跟端口没关系。
        // 这种情况报"端口被占用"纯属误导，放行让内核自己去试。
        guard fd >= 0 else { return true }
        defer { close(fd) }

        // 必须和内核用同样的选项测，否则测出来的结论对不上：
        // Go 的 net.Listen 默认带 SO_REUSEADDR，能绑上还处在 TIME_WAIT 的端口；
        // 这里不带的话，代理刚停、浏览器那些连接还在 TIME_WAIT 时就会 bind 失败，
        // 于是报"端口被占用"，可 lsof 又查不到任何监听者 —— 两边对不上正是这么来的。
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port)).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let ok = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if ok != 0 { lastBindErrno = errno }
        return ok == 0
    }

    /// 上一次 bind 失败的 errno，用来在日志里说清楚到底为什么失败
    private(set) static var lastBindErrno: Int32 = 0

    static var lastBindReason: String {
        guard lastBindErrno != 0 else { return "未知" }
        return "\(String(cString: strerror(lastBindErrno)))(errno \(lastBindErrno))"
    }
}

extension PortPicker {
    /// 查出是哪个进程占着这个端口。
    /// "端口被占用"这句话本身没法让人往下走一步，得说清楚是谁占的。
    static func occupant(of port: Int) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        let lines = (String(data: data, encoding: .utf8) ?? "")
            .split(separator: "\n").dropFirst()      // 首行是表头
        guard let first = lines.first else { return nil }
        let cols = first.split(separator: " ", omittingEmptySubsequences: true)
        guard cols.count >= 2 else { return nil }
        return "\(cols[0])(PID \(cols[1]))"
    }
}
