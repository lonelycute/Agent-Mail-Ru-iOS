import Foundation
import Network
import Combine

// MARK: - Модели

struct MRIMContact: Identifiable, Hashable {
    var id: String { email }
    let email: String
    var nick: String
    var status: UInt32

    var statusText: String {
        switch status & 0xFF {
        case 1: return "онлайн"
        case 2: return "отошёл"
        case 3: return "неизвестно"
        default: return "офлайн"
        }
    }
}

struct MRIMMessage: Identifiable {
    let id = UUID()
    let peer: String      // email собеседника
    let text: String
    let incoming: Bool
    let date = Date()
}

// MARK: - Константы протокола

private enum Msg {
    static let hello: UInt32       = 0x1001
    static let helloAck: UInt32    = 0x1002
    static let loginAck: UInt32    = 0x1004
    static let loginRej: UInt32    = 0x1005
    static let ping: UInt32        = 0x1006
    static let message: UInt32     = 0x1008
    static let messageAck: UInt32  = 0x1009
    static let userStatus: UInt32  = 0x100F
    static let messageRecv: UInt32 = 0x1011
    static let messageStatus: UInt32 = 0x1012
    static let logout: UInt32      = 0x1013
    static let contactList2: UInt32 = 0x1037
    static let login2: UInt32      = 0x1038
}

private let messageFlagNoRecv: UInt32 = 0x04

// MARK: - Упаковка и разбор байтов

private func le(_ v: UInt32) -> [UInt8] {
    [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
}

private func readU32(_ a: [UInt8], _ o: Int) -> UInt32 {
    let b0 = UInt32(a[o])
    let b1 = UInt32(a[o + 1]) << 8
    let b2 = UInt32(a[o + 2]) << 16
    let b3 = UInt32(a[o + 3]) << 24
    return b0 | b1 | b2 | b3
}

private func packUL(_ v: UInt32) -> [UInt8] { le(v) }

private func packLPS(_ s: String) -> [UInt8] {
    let b = [UInt8](s.data(using: .windowsCP1251, allowLossyConversion: true) ?? Data())
    return le(UInt32(b.count)) + b
}

/// Строки приходят то в cp1251, то в UTF-16LE.
/// В UTF-16LE старшие байты (нечётные позиции) почти всегда 0x00 (латиница) или 0x04 (кириллица).
private func decodeMRIM(_ b: [UInt8]) -> String {
    if b.isEmpty { return "" }
    if b.count % 2 == 0 {
        var hi = 0
        var i = 1
        while i < b.count {
            if b[i] == 0 || b[i] == 4 { hi += 1 }
            i += 2
        }
        if hi * 4 >= (b.count / 2) * 3,
           let s = String(data: Data(b), encoding: .utf16LittleEndian) {
            return s
        }
    }
    return String(data: Data(b), encoding: .windowsCP1251) ?? ""
}

private struct ByteReader {
    let d: [UInt8]
    var p = 0
    init(_ d: [UInt8]) { self.d = d }
    var left: Int { d.count - p }

    mutating func ul() -> UInt32? {
        guard left >= 4 else { return nil }
        let v = readU32(d, p)
        p += 4
        return v
    }

    mutating func lps() -> [UInt8]? {
        guard let n = ul(), left >= Int(n) else { return nil }
        let b = Array(d[p..<(p + Int(n))])
        p += Int(n)
        return b
    }
}

private enum Field {
    case num(UInt32)
    case str(String)
    var s: String { if case .str(let v) = self { return v } else { return "" } }
    var n: UInt32 { if case .num(let v) = self { return v } else { return 0 } }
}

// MARK: - Клиент

final class MRIMClient: ObservableObject {
    @Published var state = "Не подключён"
    @Published var loggedIn = false
    @Published var contacts: [MRIMContact] = []
    @Published var messages: [MRIMMessage] = []

    private let registrarHost = "proto.mrim.su"
    private let registrarPort: UInt16 = 2042
    private let proto: UInt32 = 0x00010017

    private let queue = DispatchQueue(label: "mrim.client")
    private var conn: NWConnection?
    private var seq: UInt32 = 0
    private var buffer = [UInt8]()
    private var pingTimer: DispatchSourceTimer?
    private var login = ""
    private var password = ""

    // MARK: публичный API

    func connect(login: String, password: String) {
        self.login = login
        self.password = password
        setState("Ищу сервер…")
        fetchServer { [weak self] host, port in
            guard let self else { return }
            guard let host, let port else {
                self.setState("Не удалось получить адрес сервера")
                return
            }
            self.openMain(host: host, port: port)
        }
    }

    func sendMessage(to: String, text: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.sendPacket(Msg.message, packUL(0) + packLPS(to) + packLPS(text) + packLPS(" "))
            DispatchQueue.main.async {
                self.messages.append(MRIMMessage(peer: to.lowercased(), text: text, incoming: false))
            }
        }
    }

    func disconnect() {
        queue.async { [weak self] in
            self?.teardown()
            self?.setState("Отключён")
        }
    }

    // MARK: подключение

    /// Порт 2042 отдаёт строку "ip:port" и закрывает соединение.
    private func fetchServer(_ done: @escaping (String?, UInt16?) -> Void) {
        let c = NWConnection(host: NWEndpoint.Host(registrarHost),
                             port: NWEndpoint.Port(rawValue: registrarPort)!,
                             using: .tcp)
        var finished = false
        func finish(_ h: String?, _ p: UInt16?) {
            if finished { return }
            finished = true
            c.cancel()
            done(h, p)
        }
        c.stateUpdateHandler = { st in
            switch st {
            case .ready:
                c.receive(minimumIncompleteLength: 1, maximumLength: 200) { data, _, _, err in
                    guard let data, err == nil,
                          let s = String(data: data, encoding: .utf8) else {
                        finish(nil, nil); return
                    }
                    let parts = s.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
                    if parts.count == 2, let p = UInt16(parts[1]) {
                        finish(String(parts[0]), p)
                    } else {
                        finish(nil, nil)
                    }
                }
            case .failed, .cancelled:
                finish(nil, nil)
            default:
                break
            }
        }
        c.start(queue: queue)
    }

    private func openMain(host: String, port: UInt16) {
        setState("Подключаюсь к \(host):\(port)…")
        let c = NWConnection(host: NWEndpoint.Host(host),
                             port: NWEndpoint.Port(rawValue: port)!,
                             using: .tcp)
        conn = c
        buffer.removeAll()
        seq = 0
        c.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready:
                self.setState("Соединение установлено")
                self.sendPacket(Msg.hello)
                self.receiveLoop()
            case .failed(let e):
                self.setState("Ошибка: \(e.localizedDescription)")
                self.teardown()
            default:
                break
            }
        }
        c.start(queue: queue)
    }

    private func teardown() {
        pingTimer?.cancel()
        pingTimer = nil
        conn?.cancel()
        conn = nil
        DispatchQueue.main.async { self.loggedIn = false }
    }

    private func setState(_ s: String) {
        DispatchQueue.main.async { self.state = s }
    }

    // MARK: приём и отправка пакетов

    private func sendPacket(_ msg: UInt32, _ body: [UInt8] = []) {
        seq += 1
        var d = [UInt8]()
        let header: [UInt32] = [0xDEADBEEF, proto, seq, msg, UInt32(body.count), 0, 0]
        for v in header { d += le(v) }
        d += [UInt8](repeating: 0, count: 16)
        d += body
        conn?.send(content: Data(d), completion: .contentProcessed { _ in })
    }

    private func receiveLoop() {
        conn?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(contentsOf: data)
                self.drain()
            }
            if error != nil || isComplete {
                self.setState("Соединение закрыто")
                self.teardown()
                return
            }
            self.receiveLoop()
        }
    }

    private func drain() {
        while buffer.count >= 44 {
            guard readU32(buffer, 0) == 0xDEADBEEF else {
                setState("Плохой magic в пакете")
                teardown()
                return
            }
            let msg = readU32(buffer, 12)
            let dlen = Int(readU32(buffer, 16))
            if buffer.count < 44 + dlen { return }
            let body = Array(buffer[44..<(44 + dlen)])
            buffer.removeFirst(44 + dlen)
            handle(msg, body)
        }
    }

    private func startPing(_ seconds: Double) {
        pingTimer?.cancel()
        let sec = max(seconds, 5)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + sec, repeating: sec)
        t.setEventHandler { [weak self] in self?.sendPacket(Msg.ping) }
        t.resume()
        pingTimer = t
    }

    // MARK: обработка пакетов

    private func handle(_ msg: UInt32, _ body: [UInt8]) {
        switch msg {
        case Msg.helloAck:
            var r = ByteReader(body)
            startPing(Double(r.ul() ?? 10))
            sendPacket(Msg.login2,
                       packLPS(login) + packLPS(password) + packUL(1) + packLPS("swiftclient 0.1"))

        case Msg.loginAck:
            setState("Вход выполнен")
            DispatchQueue.main.async { self.loggedIn = true }

        case Msg.loginRej:
            let text = decodeMRIM(body).filter { !$0.isASCII || $0.isLetter || $0 == " " }
            setState("Вход отклонён: \(text)")
            teardown()

        case Msg.contactList2:
            parseContacts(body)

        case Msg.messageAck:
            var r = ByteReader(body)
            guard let id = r.ul(), let flags = r.ul(),
                  let fromB = r.lps(), let textB = r.lps() else { return }
            let sender = decodeMRIM(fromB)
            let text = decodeMRIM(textB)
            if flags & messageFlagNoRecv == 0 {
                sendPacket(Msg.messageRecv, packLPS(sender) + packUL(id))
            }
            DispatchQueue.main.async {
                self.messages.append(MRIMMessage(peer: sender.lowercased(), text: text, incoming: true))
            }

        case Msg.messageStatus:
            break

        case Msg.userStatus:
            var r = ByteReader(body)
            guard let st = r.ul(),
                  r.lps() != nil, r.lps() != nil, r.lps() != nil,
                  let userB = r.lps() else { return }
            let user = decodeMRIM(userB).lowercased()
            DispatchQueue.main.async {
                if let i = self.contacts.firstIndex(where: { $0.email.lowercased() == user }) {
                    self.contacts[i].status = st
                }
            }

        case Msg.logout:
            setState("Сервер завершил сессию")
            teardown()

        default:
            break
        }
    }

    private func parseContacts(_ body: [UInt8]) {
        var r = ByteReader(body)
        guard let status = r.ul(), status == 0,
              let groupCount = r.ul(),
              let gMaskB = r.lps(), let cMaskB = r.lps() else { return }
        let gMask = String(decoding: gMaskB, as: UTF8.self)
        let cMask = String(decoding: cMaskB, as: UTF8.self)

        func readFields(_ mask: String, _ r: inout ByteReader) -> [Field]? {
            var out = [Field]()
            for ch in mask {
                switch ch {
                case "u":
                    guard let v = r.ul() else { return nil }
                    out.append(.num(v))
                case "s", "z":
                    guard let b = r.lps() else { return nil }
                    out.append(.str(decodeMRIM(b)))
                default:
                    return nil
                }
            }
            return out
        }

        for _ in 0..<Int(groupCount) {
            guard readFields(gMask, &r) != nil else { return }
        }

        var list = [MRIMContact]()
        while r.left > 0 {
            // стандартные поля: flags, group, email, nick, server_flags, status
            guard let f = readFields(cMask, &r), f.count >= 6 else { break }
            list.append(MRIMContact(email: f[2].s, nick: f[3].s, status: f[5].n))
        }
        DispatchQueue.main.async { self.contacts = list }
    }
}
