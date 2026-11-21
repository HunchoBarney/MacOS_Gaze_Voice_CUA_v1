import SwiftUI

/// The fixture Mac every component is drawn on: a 14-inch MacBook Pro's
/// logical display (1512 x 982 pt), the menu bar, the notch with the camera,
/// a generated wallpaper and one fixture Mail compose window. Fixture text
/// only; nothing here is real screen content.
public enum Desk {
    public static let size = CGSize(width: 1512, height: 982)
    public static let menuBar: CGFloat = 37
    public static let notch = CGRect(x: (1512 - 185) / 2, y: 0, width: 185, height: 37)
    /// The notch's lower corners.
    public static let notchRadius: CGFloat = 10
    public static var full: CGRect { CGRect(origin: .zero, size: size) }

    public static let mail = CGRect(x: 346, y: 191, width: 820, height: 560)
    /// Controls inside the Mail window, in desktop points.
    public enum Target {
        public static let send = CGRect(x: Desk.mail.minX + 96, y: Desk.mail.minY + 13, width: 74, height: 28)
        public static let to = CGRect(x: Desk.mail.minX + 18, y: Desk.mail.minY + 62, width: 784, height: 34)
        public static let subject = CGRect(x: Desk.mail.minX + 18, y: Desk.mail.minY + 134, width: 784, height: 34)
        public static let attach = CGRect(x: Desk.mail.maxX - 128, y: Desk.mail.minY + 13, width: 30, height: 28)
        public static let format = CGRect(x: Desk.mail.maxX - 90, y: Desk.mail.minY + 13, width: 30, height: 28)
        public static let paragraph = CGRect(x: Desk.mail.minX + 28, y: Desk.mail.minY + 200, width: 700, height: 120)
    }
}

/// Mail compose content, in window points; Desk.Target mirrors these frames.
private enum MailCopy {
    static let to = "Alex Rivera"
    static let subject = "Q4 deck"
    static let body = [
        "Hi Alex,",
        "",
        "The deck for Thursday is ready. I moved the pricing slides to the end and",
        "added the two customer quotes you asked for. The appendix has the raw",
        "numbers if anyone wants to dig in before the meeting.",
        "",
        "Thanks,",
        "Sam",
    ]
}

public struct MacDesktop: View {
    var scheme: ColorScheme
    var showsMail: Bool
    var reduceTransparency: Bool

    public init(scheme: ColorScheme, showsMail: Bool = true, reduceTransparency: Bool = false) {
        self.scheme = scheme
        self.showsMail = showsMail
        self.reduceTransparency = reduceTransparency
    }

    private var dark: Bool { scheme == .dark }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            wallpaper
            if showsMail { mail.offset(x: Desk.mail.minX, y: Desk.mail.minY) }
            menuBar
            notch
        }
        .frame(width: Desk.size.width, height: Desk.size.height, alignment: .topLeading)
        .environment(\.colorScheme, scheme)
    }

    private var wallpaper: some View {
        let colors: [Color] = dark
            ? [Color(red: 0.05, green: 0.06, blue: 0.16), Color(red: 0.10, green: 0.09, blue: 0.30), Color(red: 0.03, green: 0.10, blue: 0.22),
               Color(red: 0.16, green: 0.10, blue: 0.36), Color(red: 0.22, green: 0.20, blue: 0.55), Color(red: 0.06, green: 0.22, blue: 0.40),
               Color(red: 0.04, green: 0.05, blue: 0.12), Color(red: 0.12, green: 0.08, blue: 0.24), Color(red: 0.03, green: 0.08, blue: 0.16)]
            : [Color(red: 0.80, green: 0.86, blue: 0.98), Color(red: 0.88, green: 0.84, blue: 0.98), Color(red: 0.78, green: 0.90, blue: 0.98),
               Color(red: 0.92, green: 0.86, blue: 0.96), Color(red: 0.70, green: 0.76, blue: 0.98), Color(red: 0.76, green: 0.88, blue: 0.96),
               Color(red: 0.86, green: 0.90, blue: 0.98), Color(red: 0.90, green: 0.86, blue: 0.94), Color(red: 0.82, green: 0.90, blue: 0.96)]
        return MeshGradient(width: 3, height: 3, points: [
            [0, 0], [0.55, 0], [1, 0],
            [0, 0.45], [0.42, 0.58], [1, 0.40],
            [0, 1], [0.60, 1], [1, 1],
        ], colors: colors)
        .frame(width: Desk.size.width, height: Desk.size.height)
    }

    private var menuBar: some View {
        let ink = dark ? Color.white : Color.black.opacity(0.85)
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(dark ? Color.black.opacity(reduceTransparency ? 0.85 : 0.22) : Color.white.opacity(reduceTransparency ? 0.95 : 0.35))
                .frame(width: Desk.size.width, height: Desk.menuBar)
            HStack(spacing: 18) {
                Image(systemName: "apple.logo").font(.system(size: 15, weight: .medium))
                Text("Mail").font(.system(size: 13.5, weight: .bold))
                ForEach(["File", "Edit", "View", "Mailbox", "Message", "Format", "Window", "Help"], id: \.self) {
                    Text($0).font(.system(size: 13.5))
                }
            }
            .foregroundStyle(ink)
            .frame(height: Desk.menuBar)
            .padding(.leading, 20)
            HStack(spacing: 16) {
                Image(systemName: "battery.75percent")
                Image(systemName: "wifi")
                Image(systemName: "magnifyingglass")
                Image(systemName: "switch.2")
                Text("Fri Nov 21  9:41 AM")
            }
            .font(.system(size: 13.5, weight: .medium))
            .foregroundStyle(ink)
            .frame(width: Desk.size.width - 20, height: Desk.menuBar, alignment: .trailing)
        }
    }

    private var notch: some View {
        NotchSilhouette(width: Desk.notch.width, height: Desk.notch.height, ear: 0, bottomRadius: Desk.notchRadius)
            .fill(Color.black)
            .frame(width: Desk.notch.width + 12, height: Desk.notch.height)
            .offset(x: Desk.notch.minX - 6)
    }

    private var mail: some View {
        let surface = dark ? Color(white: 0.13) : Color(white: 0.99)
        let rule = dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)
        let label = dark ? Color.white.opacity(0.45) : Color.black.opacity(0.45)
        let ink = dark ? Color.white.opacity(0.92) : Color.black.opacity(0.88)
        let mailSize = Desk.mail.size
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(surface)
            // Toolbar
            Rectangle().fill(dark ? Color(white: 0.17) : Color(white: 0.965)).frame(height: 54)
            HStack(spacing: 8) {
                ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18), Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) {
                    Circle().fill($0).frame(width: 12, height: 12)
                }
            }
            .offset(x: 20, y: 21)
            fixtureButton(label: "Send", symbol: "paperplane.fill", ink: ink, frame: Desk.Target.send)
            Image(systemName: "paperclip").font(.system(size: 15)).foregroundStyle(ink.opacity(0.75))
                .frame(width: Desk.Target.attach.width, height: Desk.Target.attach.height)
                .offset(x: Desk.Target.attach.minX - Desk.mail.minX, y: Desk.Target.attach.minY - Desk.mail.minY)
            Image(systemName: "textformat").font(.system(size: 15)).foregroundStyle(ink.opacity(0.75))
                .frame(width: Desk.Target.format.width, height: Desk.Target.format.height)
                .offset(x: Desk.Target.format.minX - Desk.mail.minX, y: Desk.Target.format.minY - Desk.mail.minY)
            Text("Q4 deck").font(.system(size: 13, weight: .semibold)).foregroundStyle(ink.opacity(0.7))
                .frame(width: mailSize.width, height: 54)
            field("To:", MailCopy.to, frame: Desk.Target.to, label: label, ink: ink, rule: rule)
            field("Cc:", "", frame: Desk.Target.to.offsetBy(dx: 0, dy: 36), label: label, ink: ink, rule: rule)
            field("Subject:", MailCopy.subject, frame: Desk.Target.subject, label: label, ink: ink, rule: rule)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(MailCopy.body.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line).font(.system(size: 14)).foregroundStyle(ink)
                }
            }
            .offset(x: Desk.Target.paragraph.minX - Desk.mail.minX, y: Desk.Target.paragraph.minY - Desk.mail.minY)
        }
        .frame(width: mailSize.width, height: mailSize.height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(dark ? Color.white.opacity(0.10) : Color.black.opacity(0.10), lineWidth: 0.5))
        .shadow(color: .black.opacity(dark ? 0.5 : 0.18), radius: 30, y: 16)
    }

    private func fixtureButton(label: String, symbol: String, ink: Color, frame: CGRect) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
            Text(label).font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(ink)
        .frame(width: frame.width, height: frame.height)
        .background(dark ? Color.white.opacity(0.10) : Color.black.opacity(0.06), in: Capsule())
        .offset(x: frame.minX - Desk.mail.minX, y: frame.minY - Desk.mail.minY)
    }

    private func field(_ title: String, _ value: String, frame: CGRect, label: Color, ink: Color, rule: Color) -> some View {
        ZStack(alignment: .bottomLeading) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 14)).foregroundStyle(label)
                Text(value).font(.system(size: 14)).foregroundStyle(ink)
            }
            .frame(width: frame.width, height: frame.height, alignment: .leading)
            .padding(.leading, 10)
            Rectangle().fill(rule).frame(width: frame.width, height: 1)
        }
        .offset(x: frame.minX - Desk.mail.minX, y: frame.minY - Desk.mail.minY)
    }
}

/// The notch's outline, and the island that grows out of it: flat top flush
/// with the display edge, concave shoulders ("ears") where it meets the menu
/// bar, continuous lower corners. Geometry follows DynamicNotchKit's
/// NotchShape (MIT, Kai Azim): quad-curve shoulders into a rounded bottom.
public struct NotchSilhouette: Shape {
    public var width: CGFloat
    public var height: CGFloat
    /// The concave shoulder radius at the top corners.
    public var ear: CGFloat
    public var bottomRadius: CGFloat

    public init(width: CGFloat, height: CGFloat, ear: CGFloat = 6, bottomRadius: CGFloat) {
        self.width = width
        self.height = height
        self.ear = ear
        self.bottomRadius = bottomRadius
    }

    public var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(.init(width, height), .init(ear, bottomRadius)) }
        set {
            width = newValue.first.first
            height = newValue.first.second
            ear = newValue.second.first
            bottomRadius = newValue.second.second
        }
    }

    public func path(in rect: CGRect) -> Path {
        let shoulder = max(6, ear)
        let x0 = rect.midX - width / 2
        let x1 = rect.midX + width / 2
        let r = min(bottomRadius, height / 2, width / 2)
        var p = Path()
        p.move(to: CGPoint(x: x0 - shoulder, y: rect.minY))
        p.addLine(to: CGPoint(x: x1 + shoulder, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: x1, y: rect.minY + shoulder), control: CGPoint(x: x1, y: rect.minY))
        p.addLine(to: CGPoint(x: x1, y: rect.minY + height - r))
        p.addCurve(to: CGPoint(x: x1 - r, y: rect.minY + height),
                   control1: CGPoint(x: x1, y: rect.minY + height - r * 0.45),
                   control2: CGPoint(x: x1 - r * 0.45, y: rect.minY + height))
        p.addLine(to: CGPoint(x: x0 + r, y: rect.minY + height))
        p.addCurve(to: CGPoint(x: x0, y: rect.minY + height - r),
                   control1: CGPoint(x: x0 + r * 0.45, y: rect.minY + height),
                   control2: CGPoint(x: x0, y: rect.minY + height - r * 0.45))
        p.addLine(to: CGPoint(x: x0, y: rect.minY + shoulder))
        p.addQuadCurve(to: CGPoint(x: x0 - shoulder, y: rect.minY), control: CGPoint(x: x0, y: rect.minY))
        p.closeSubpath()
        return p
    }
}
