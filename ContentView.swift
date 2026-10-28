import SwiftUI

// MARK: - Фон (стеклу нужно, что преломлять)

struct AppBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.04, green: 0.09, blue: 0.22),
                         Color(red: 0.08, green: 0.30, blue: 0.42),
                         Color(red: 0.04, green: 0.38, blue: 0.28)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(Color.green.opacity(0.45)).frame(width: 280)
                .blur(radius: 70).offset(x: -120, y: -230)
            Circle().fill(Color.blue.opacity(0.5)).frame(width: 320)
                .blur(radius: 80).offset(x: 140, y: 120)
            Circle().fill(Color.mint.opacity(0.35)).frame(width: 240)
                .blur(radius: 70).offset(x: -80, y: 330)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Корень

struct ContentView: View {
    @StateObject private var client = MRIMClient()

    var body: some View {
        NavigationStack {
            if client.loggedIn {
                ContactsView(client: client)
            } else {
                LoginView(client: client)
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Вход

struct LoginView: View {
    @ObservedObject var client: MRIMClient
    @State private var login = ""
    @State private var password = ""

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: "at.circle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(.green)
                Text("Агент")
                    .font(.largeTitle.bold())
            }

            VStack(spacing: 12) {
                TextField("логин@mail.ru", text: $login)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)
                    .padding(16)
                    .glassEffect(.regular, in: .rect(cornerRadius: 18))
                SecureField("пароль", text: $password)
                    .padding(16)
                    .glassEffect(.regular, in: .rect(cornerRadius: 18))
            }

            Button {
                client.connect(login: login, password: password)
            } label: {
                Text("Войти")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.glassProminent)
            .tint(.green)

            Text(client.state)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer()
            Spacer()
        }
        .padding(24)
        .background { AppBackground() }
    }
}

// MARK: - Контакты

struct AvatarView: View {
    let title: String
    let online: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Text(String(title.prefix(1)).uppercased())
                .font(.headline)
                .frame(width: 46, height: 46)
                .glassEffect(.regular.tint(.green.opacity(0.35)), in: .circle)
            Circle()
                .fill(online ? Color.green : Color.gray)
                .frame(width: 13, height: 13)
                .overlay(Circle().stroke(Color.black.opacity(0.35), lineWidth: 1))
        }
    }
}

struct ContactRow: View {
    let contact: MRIMContact

    private var name: String { contact.nick.isEmpty ? contact.email : contact.nick }
    private var online: Bool { contact.status & 0xFF == 1 }

    var body: some View {
        HStack(spacing: 14) {
            AvatarView(title: name, online: online)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.headline)
                Text("\(contact.email) · \(contact.statusText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24))
    }
}

struct ContactsView: View {
    @ObservedObject var client: MRIMClient

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(client.contacts) { c in
                    NavigationLink(value: c) {
                        ContactRow(contact: c)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .navigationTitle("Агент")
        .navigationDestination(for: MRIMContact.self) { contact in
            ChatView(client: client, contact: contact)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Выйти") { client.disconnect() }
            }
        }
        .background { AppBackground() }
    }
}

// MARK: - Чат

struct BubbleView: View {
    let message: MRIMMessage

    var body: some View {
        HStack {
            if !message.incoming { Spacer(minLength: 48) }
            Text(message.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassEffect(
                    message.incoming ? .regular : .regular.tint(.green.opacity(0.55)),
                    in: .rect(cornerRadius: 20))
            if message.incoming { Spacer(minLength: 48) }
        }
    }
}

struct ChatView: View {
    @ObservedObject var client: MRIMClient
    let contact: MRIMContact
    @State private var text = ""

    private var thread: [MRIMMessage] {
        client.messages.filter { $0.peer == contact.email.lowercased() }
    }
    private var title: String { contact.nick.isEmpty ? contact.email : contact.nick }
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(thread) { m in
                        BubbleView(message: m).id(m.id)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }
            .onChange(of: thread.count) { _, _ in
                if let last = thread.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .safeAreaInset(edge: .bottom) { inputBar }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .background { AppBackground() }
    }

    private var inputBar: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                TextField("Сообщение", text: $text, axis: .vertical)
                    .lineLimit(1...4)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .glassEffect(.regular, in: .capsule)
                Button {
                    guard !trimmed.isEmpty else { return }
                    client.sendMessage(to: contact.email, text: trimmed)
                    text = ""
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.headline)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .tint(.green)
                .disabled(trimmed.isEmpty)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}

#Preview {
    ContentView()
}
