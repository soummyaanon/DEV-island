import AppKit
import Foundation

// Agent Island's native sidecar — the few AppKit surfaces Electron doesn't
// expose. One long-lived process, newline-delimited text on stdin/stdout:
//
//   → ping                                ← pong
//   → haptic levelChange,55,levelChange   ← ok
//   → quit                                (exits)
//
// Long-lived rather than spawned per call because haptics need sub-10ms
// latency; an `osascript` round trip costs 150ms+ and a process spawn. Closing
// our stdin is the shutdown signal: readLine returns nil and we fall out.
//
// Every caller treats this binary's absence as a normal state, so nothing here
// needs to be defensive about being unavailable — only about bad input.

/// The complete set macOS offers. There is no waveform control and no
/// intensity, so a recognisable "feel" comes from count and spacing alone —
/// which is why the protocol takes a rhythm rather than a single pattern.
let feedbackPatterns: [String: NSHapticFeedbackManager.FeedbackPattern] = [
  "generic": .generic,
  "alignment": .alignment,
  "levelChange": .levelChange,
]

/// One step of a rhythm: a pattern, then how long to wait before the next.
private struct Step {
  let pattern: NSHapticFeedbackManager.FeedbackPattern
  let gapMs: Int
}

/// Longest gap we'll honour between two taps. A rhythm that outlasts the
/// gesture that triggered it stops reading as feedback and starts reading as a
/// malfunction.
private let maxGapMs = 500

private struct RhythmError: Error {
  let reason: String
}

/// Parse an alternating `pattern,gap,pattern,...` spec. Resolved in full
/// before anything is performed, so a typo is a clean no-op with a useful
/// error rather than half a rhythm played against the user's hand.
private func parseRhythm(_ spec: String) -> Result<[Step], RhythmError> {
  let parts = spec.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
  guard !parts.isEmpty, !(parts.count == 1 && parts[0].isEmpty) else {
    return .failure(RhythmError(reason: "empty-rhythm"))
  }

  var steps: [Step] = []
  var index = 0
  while index < parts.count {
    guard let pattern = feedbackPatterns[parts[index]] else {
      return .failure(RhythmError(reason: "unknown-pattern \(parts[index])"))
    }
    // A trailing number is this step's gap; its absence ends the rhythm.
    var gap = 0
    if index + 1 < parts.count, let ms = Int(parts[index + 1]) {
      gap = min(max(0, ms), maxGapMs)
      index += 2
    } else {
      index += 1
    }
    steps.append(Step(pattern: pattern, gapMs: gap))
  }
  return .success(steps)
}

private func performRhythm(_ spec: String) -> String {
  let steps: [Step]
  switch parseRhythm(spec) {
  case .failure(let error): return "err \(error.reason)"
  case .success(let parsed): steps = parsed
  }

  let performer = NSHapticFeedbackManager.defaultPerformer
  var offset = 0
  for step in steps {
    if offset == 0 {
      performer.perform(step.pattern, performanceTime: .now)
    } else {
      // A global queue, deliberately: the main thread is parked in readLine
      // with no run loop, so anything scheduled onto it would never fire.
      DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(offset)) {
        performer.perform(step.pattern, performanceTime: .now)
      }
    }
    offset += step.gapMs
  }
  return "ok"
}

private func respond(_ line: String) {
  print(line)
  // stdout is a pipe here, so it's block-buffered — without this the parent
  // waits on a reply that's sitting in our buffer.
  fflush(stdout)
}

while let line = readLine(strippingNewline: true) {
  let input = line.trimmingCharacters(in: .whitespaces)
  if input.isEmpty { continue }

  let split = input.firstIndex(of: " ")
  let command = split.map { String(input[input.startIndex..<$0]) } ?? input
  let argument = split.map { String(input[input.index(after: $0)...]) } ?? ""

  switch command {
  case "ping": respond("pong")
  case "haptic": respond(performRhythm(argument))
  case "quit": exit(0)
  default: respond("err unknown-command \(command)")
  }
}
