import SwiftUI
import UniformTypeIdentifiers

/// WebDAV 备份目标设置。地址和用户名进配置，密码存钥匙串。
struct WebDAVSettingsView: View {
    @EnvironmentObject var app: AppState
    @Binding var show: Bool
    @State private var url = ""
    @State private var username = ""
    @State private var password = ""
    @State private var directory = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("WebDAV 设置")
                .font(.system(size: 14, weight: .semibold))

            TextField("服务器地址", text: $url)
                .textFieldStyle(.roundedBorder)
            TextField("用户名", text: $username)
                .textFieldStyle(.roundedBorder)
            SecureField("密码（存系统钥匙串）", text: $password)
                .textFieldStyle(.roundedBorder)
            TextField("备份目录（留空默认 EchOS_Backup）", text: $directory)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("取消") { show = false }
                Button("保存") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 400)
        .onAppear {
            if let w = app.config.webdav {
                url = w.url
                username = w.username
                password = app.webdavPassword ?? ""
                directory = w.directory
            }
        }
    }

    private func save() {
        app.saveWebDAV(url: url, username: username, password: password, directory: directory)
        show = false
    }
}
