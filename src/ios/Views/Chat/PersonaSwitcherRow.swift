import SwiftUI

// MARK: - PersonaAvatarView
//
// 把 Persona.avatar（文件引用 "avatars/….png"，或老版本的
// data:image/png;base64,…）渲染成圆形头像；没设头像时用系统 person
// 图标。跟 App 其他地方一样不用 emoji。

struct PersonaAvatarView: View {
    let iconRef: String?
    var size: CGFloat = 28

    private var uiImage: UIImage? {
        guard let uri = iconRef, !uri.isEmpty else { return nil }
        // [avatar-file] One shared decoder: path references and legacy
        // inline values both resolve here.
        return SoulIconImage.decode(uri)
    }

    var body: some View {
        Group {
            if let img = uiImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "person.circle.fill")
                    .resizable()
                    .foregroundStyle(MinisTheme.secondaryText)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}
