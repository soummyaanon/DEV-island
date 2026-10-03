import AppKit
import IslandCore
import SwiftUI

// The main page's tiles: one glance each, glyphs instead of words.

struct CallTile: View {
  let model: IslandModel
  let call: MeetingService.Call
  let now: Date

  var body: some View {
    let meeting = model.meeting
    QuickCard(tint: QuickPalette.meeting) {
      HStack(spacing: 6) {
        Button { meeting.show() } label: {
          HStack(spacing: 6) {
            CallBadge(muted: meeting.muted)
            Text(Clock.elapsed(now.timeIntervalSince(call.since))).islandFont(12, weight: .semibold).monospacedDigit().foregroundStyle(Palette.text)
          }
        }
        .buttonStyle(.plain)
        .help("\(call.source.name) — show the call")
        Spacer(minLength: 2)
        QuickButton(symbol: meeting.muted == true ? "mic.slash.fill" : "mic.fill", label: meeting.muted == true ? "Unmute" : "Mute", tint: meeting.muted == true ? QuickPalette.muted : nil) {
          meeting.toggleMute()
        }
        QuickButton(symbol: meeting.videoOn == false ? "video.slash.fill" : "video.fill", label: meeting.videoOn == false ? "Start video" : "Stop video", tint: meeting.videoOn == false ? QuickPalette.muted : nil) {
          meeting.toggleVideo()
        }
        QuickButton(symbol: "phone.down.fill", label: "Leave", tint: QuickPalette.muted) { meeting.leave() }
      }
    }
    .accessibilityLabel("\(call.source.name) call, \(Clock.elapsed(now.timeIntervalSince(call.since)))")
  }
}

struct EventTile: View {
  let model: IslandModel
  let event: AgendaService.Event
  let now: Date

  var body: some View {
    QuickCard {
      HStack(spacing: 6) {
        RoundedRectangle(cornerRadius: 2).fill(event.color.map(Color.init(nsColor:)) ?? Palette.accent).frame(width: 3, height: 22)
        VStack(alignment: .leading, spacing: 0) {
          Text(event.title).islandFont(11, weight: .semibold).foregroundStyle(Palette.text).lineLimit(1)
          Text(event.start, style: .relative).islandFont(9.5).foregroundStyle(Palette.textDim).lineLimit(1)
        }
        Spacer(minLength: 2)
        if event.service != nil {
          QuickButton(symbol: "video.fill", label: "Join", tint: QuickPalette.meeting) { model.agenda.join(event) }
        }
      }
    }
    .help(AgendaText.when(event, now: now))
  }
}

struct TimerTile: View {
  let model: IslandModel
  let timer: IslandTimer
  let now: Date

  var body: some View {
    let timers = model.timers
    QuickCard {
      HStack(spacing: 6) {
        TimerRing(timer: timer, now: now, size: 18, lineWidth: 2.2)
        Text(Clock.countdown(timer.remaining(at: now)))
          .islandFont(14, weight: .semibold)
          .monospacedDigit()
          .foregroundStyle(timer.isPaused ? Palette.textDim : QuickPalette.timer(timer))
          .contentTransition(.numericText(countsDown: true))
        Spacer(minLength: 2)
        QuickButton(symbol: timer.isPaused ? "play.fill" : "pause.fill", label: timer.isPaused ? "Resume" : "Pause") { timers.togglePause(timer.id) }
        if timer.kind == .pomodoro {
          QuickButton(symbol: "forward.end.fill", label: "Next phase") { timers.skip(timer.id) }
        }
        QuickButton(symbol: "xmark", label: "Stop") { timers.cancel(timer.id) }
      }
    }
    .help(timer.title)
    .accessibilityLabel("\(timer.title), \(Clock.countdown(timer.remaining(at: now))) left")
  }
}

struct MediaTile: View {
  let model: IslandModel
  let track: NowPlayingService.Track

  var body: some View {
    let media = model.media
    QuickCard {
      HStack(spacing: 6) {
        Button { media.openSource() } label: { ArtworkView(image: media.artwork, size: 26, radius: 6) }
          .buttonStyle(.plain)
        Text(track.title).islandFont(11, weight: .semibold).foregroundStyle(Palette.text).lineLimit(1)
        Spacer(minLength: 2)
        QuickButton(symbol: "backward.fill", label: "Previous", size: 10) { media.previous() }
        QuickButton(symbol: track.playing ? "pause.fill" : "play.fill", label: track.playing ? "Pause" : "Play") { media.playPause() }
        QuickButton(symbol: "forward.fill", label: "Next", size: 10) { media.next() }
      }
    }
    .help([track.title, track.artist].filter { !$0.isEmpty }.joined(separator: " — "))
    .accessibilityLabel("\(track.title) by \(track.artist)")
  }
}

struct BrowserTile: View {
  let model: IslandModel

  var body: some View {
    let service = model.browser
    QuickCard {
      HStack(spacing: 6) {
        if let browser = service.front { AppIcon(bundleId: browser.bundleId, size: 18) }
        Text(service.tab.map { displayHost($0.url) } ?? service.front?.name ?? "")
          .islandFont(10.5).foregroundStyle(Palette.textDim).lineLimit(1)
        Spacer(minLength: 2)
        QuickButton(symbol: "chevron.left", label: "Back") { service.perform(.back) }
        QuickButton(symbol: "chevron.right", label: "Forward") { service.perform(.forward) }
        QuickButton(symbol: "arrow.clockwise", label: "Reload") { service.perform(.reload) }
      }
    }
    .help(service.tab?.title ?? "")
  }
}

struct FilesTile: View {
  let model: IslandModel

  var body: some View {
    let shelf = model.shelf
    QuickCard {
      HStack(spacing: 4) {
        ForEach(shelf.items.suffix(3)) { item in
          Image(nsImage: shelf.icon(item)).resizable().aspectRatio(contentMode: .fit).frame(width: 22, height: 22)
            .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
            .help(item.name)
        }
        if shelf.items.count > 3 {
          Text("+\(shelf.items.count - 3)").islandFont(10, weight: .semibold).foregroundStyle(Palette.textDim)
        }
        Spacer(minLength: 2)
        DragAllHandle(urls: shelf.items.map(\.url)).frame(width: 22, height: 22).help("Drag all out")
        QuickButton(symbol: "dot.radiowaves.up.forward", label: "AirDrop") { shelf.airDrop() }
        QuickButton(symbol: "chevron.right", label: "Files") { model.showTab(.shelf) }
      }
    }
    .onDrop(of: shelfDropTypes, isTargeted: nil) { providers in
      shelf.add(providers)
      return true
    }
  }
}
