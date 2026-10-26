//
//  TogetherMiniBar.swift
//  MinisApp
//
//  一起听 · 输入栏上方的伴听微控条。
//
//  照 attachments/uploads/index.html 的 slim-bar 抄：38pt 高、19 圆角、
//  迷你黑胶（转）+ 三根音波 + 歌词视窗 + 上一首/播放/下一首，底下一条细进度线。
//  贴输入栏正上方，固定位置——不再做悬浮球，也不再自由拖。
//

import SwiftUI

struct TogetherMiniBar: View {

    /// 点歌词区打开全屏面板。
    var onOpen: () -> Void = {}

    @ObservedObject private var player = TogetherPlayer.shared

    @State private var state = TogetherState()
    @State private var lyrics: TogetherLyrics?
    @State private var wavePhase = false

    private let barHeight: CGFloat = 38

    var body: some View {
        HStack(spacing: 9) {
            miniVinyl
            waveDots
            lyricBox
            controls
        }
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .frame(height: barHeight)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: barHeight / 2, style: .continuous)
                .fill(CSSThemeVariables.card(scope: .chat))
        )
        .overlay(
            RoundedRectangle(cornerRadius: barHeight / 2, style: .continuous)
                .strokeBorder(CSSThemeVariables.divider(scope: .chat).opacity(0.4), lineWidth: 0.5)
        )
        .overlay(alignment: .bottomLeading) { progressHairline }
        .shadow(color: TogetherSkin.shadowSoft, radius: 10, x: 0, y: 3)
        .padding(.horizontal, 16)
        .padding(.bottom, 3)
        .onAppear {
            reload()
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                wavePhase = true
            }
        }
        .onChange(of: player.track?.id) { _ in reload() }
    }

    // MARK: 迷你黑胶

    private var miniVinyl: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            TogetherSkin.vinyl.opacity(0.95),
                            TogetherSkin.vinyl,
                            CSSThemeVariables.textMain(scope: .chat).opacity(0.85)
                        ],
                        center: .center,
                        startRadius: 1,
                        endRadius: 12
                    )
                )
            Circle()
                .fill(CSSThemeVariables.textDim(scope: .chat))
                .frame(width: 8, height: 8)
                .overlay(
                    Circle().strokeBorder(TogetherSkin.vinyl, lineWidth: 1.5)
                )
        }
        .frame(width: 24, height: 24)
        .rotationEffect(.degrees(player.currentTime / 4.0 * 360))
        .animation(.linear(duration: 0.5), value: player.currentTime)
        .shadow(color: .black.opacity(0.2), radius: 3, x: 0, y: 2)
    }

    // MARK: 音波

    private var waveDots: some View {
        HStack(alignment: .center, spacing: 1.5) {
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .fill(CSSThemeVariables.textDim(scope: .chat).opacity(0.85))
                    .frame(width: 2, height: i == 1 ? 10 : (i == 0 ? 6 : 5))
                    .scaleEffect(x: 1, y: wavePhase ? 1 : 0.4, anchor: .center)
                    .animation(
                        .easeInOut(duration: 0.9)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.15),
                        value: wavePhase
                    )
            }
        }
        .frame(width: 10)
        .opacity(player.isPlaying ? 1 : 0.35)
    }

    // MARK: 歌词视窗

    private var lyricBox: some View {
        Button(action: onOpen) {
            HStack(spacing: 6) {
                MarqueeText(
                    text: lineText,
                    font: ChatFont.font(11.5),
                    color: CSSThemeVariables.textMain(scope: .chat),
                    speed: 26
                )
                .frame(height: 16)

                if !tagText.isEmpty {
                    Text(tagText)
                        .font(ChatFont.font(8.5))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(CSSThemeVariables.textMain(scope: .chat).opacity(0.06))
                        )
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 控制

    private var controls: some View {
        HStack(spacing: 10) {
            Button { player.previousTrack(); reload() } label: {
                Image(systemName: "backward.fill")
                    .font(ChatFont.font(11, weight: .medium))
                    .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
            }
            .buttonStyle(.plain)

            Button { player.userToggle(); reload() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(ChatFont.font(12, weight: .semibold))
                    .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
            }
            .buttonStyle(.plain)

            Button { player.nextTrack(); reload() } label: {
                Image(systemName: "forward.fill")
                    .font(ChatFont.font(11, weight: .medium))
                    .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
            }
            .buttonStyle(.plain)
        }
        .frame(width: 74)
    }

    // MARK: 进度

    private var progressHairline: some View {
        GeometryReader { geo in
            Capsule()
                .fill(CSSThemeVariables.accent(scope: .chat).opacity(0.55))
                .frame(width: geo.size.width * progressRatio, height: 1.5)
        }
        .frame(height: 1.5)
    }

    private var progressRatio: CGFloat {
        let d = max(player.duration, 1)
        return CGFloat(min(1, max(0, player.currentTime / d)))
    }

    // MARK: 文字

    /// 有词显词，没词显我写的那句循环，都没有就显歌手。
    private var lineText: String {
        if let lyr = lyrics, lyr.timed,
           let line = lyr.line(at: player.currentTime)?.text,
           !line.trimmingCharacters(in: .whitespaces).isEmpty {
            return line
        }
        if let id = player.track?.id, let loop = state.loopLines[id],
           !loop.trimmingCharacters(in: .whitespaces).isEmpty {
            return loop
        }
        return player.track?.title ?? TogetherCopy.title
    }

    private var tagText: String {
        guard let artist = player.track?.artist, !artist.isEmpty else { return "" }
        return artist
    }

    // MARK: 数据

    private func reload() {
        state = TogetherStore.shared.load()
        lyrics = player.track.flatMap { TogetherStore.shared.lyrics(for: $0) }
    }
}


// MARK: - 走马灯

/// 一行歌词，太长就自己走；换到下一句就从头再走。
struct MarqueeText: View {

    let text: String
    let font: Font
    let color: Color
    var speed: CGFloat = 26

    @State private var textWidth: CGFloat = 0
    @State private var animate = false

    var body: some View {
        GeometryReader { geo in
            let overflow = max(0, textWidth - geo.size.width + 16)

            Text(text)
                .font(font)
                .foregroundStyle(color)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .background(
                    GeometryReader { inner in
                        Color.clear.onAppear { textWidth = inner.size.width }
                    }
                )
                .offset(x: animate ? -overflow : 0)
                .animation(
                    overflow > 1
                        ? .linear(duration: Double(overflow / max(speed, 1))).repeatForever(autoreverses: false)
                        : nil,
                    value: animate
                )
                .frame(width: geo.size.width, alignment: .leading)
                .clipped()
                .onChange(of: text) { _ in restart() }
                .onChange(of: textWidth) { _ in restart() }
                .onAppear { restart() }
        }
    }

    private func restart() {
        animate = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            animate = true
        }
    }
}
