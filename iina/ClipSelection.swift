//
//  ClipSelection.swift
//  iina
//
//  Created by grafmik on 19/9/2026.
//  Copyright © 2026 lhc. All rights reserved.
//

import Foundation

/// Selecting a clip of the current file and saving it without re-encoding.
///
/// The start and the end of the clip are marked at the playback position. When only the start is marked the clip lasts until the end
/// of the file, when only the end is marked it begins at the start of the file. The selection is shown in orange on the play slider.
/// Exporting copies the streams of the selected part into a new file placed next to the original, see `ClipExporter`.
extension PlayerCore {

  /// `True` if the start or the end of a clip has been marked.
  var hasClipSelection: Bool { info.clipStart != nil || info.clipEnd != nil }

  /// Marks the start of the clip at the current playback position.
  ///
  /// An end marked before this position is cleared, as a clip cannot end before it starts.
  func markClipStart() {
    guard info.state.loaded else { return }
    let position = mpv.getDouble(MPVProperty.timePos)
    if let end = info.clipEnd, end <= position {
      info.clipEnd = nil
    }
    info.clipStart = position
    log("Clip start set to \(position)")
    clipSelectionChanged()
    sendOSD(.clipStart(clipTimeString(position)))
  }

  /// Marks the end of the clip at the current playback position.
  ///
  /// A start marked after this position is cleared, as a clip cannot end before it starts.
  func markClipEnd() {
    guard info.state.loaded else { return }
    let position = mpv.getDouble(MPVProperty.timePos)
    if let start = info.clipStart, position <= start {
      info.clipStart = nil
    }
    info.clipEnd = position
    log("Clip end set to \(position)")
    clipSelectionChanged()
    sendOSD(.clipEnd(clipTimeString(position)))
  }

  /// Clears the start and the end of the clip.
  /// - Parameter showOSD: Whether to confirm the action with an OSD message.
  func clearClipSelection(showOSD: Bool = true) {
    guard hasClipSelection else { return }
    info.clipStart = nil
    info.clipEnd = nil
    log("Clip selection cleared")
    clipSelectionChanged()
    if showOSD {
      sendOSD(.clipCleared)
    }
  }

  /// Saves the selected clip next to the original file, keeping its quality and its codecs.
  ///
  /// The export runs in the background with its progress shown in the OSD. Once the clip is saved the selection is cleared.
  func exportClip() {
    guard info.state.loaded else { return }
    guard hasClipSelection else {
      sendOSD(.clipNotSelected)
      return
    }
    guard let url = info.currentURL, url.isFileURL, !info.isNetworkResource else {
      sendOSD(.clipNotLocalFile)
      return
    }
    guard !info.isExportingClip else {
      sendOSD(.clipExportInProgress)
      return
    }
    let start = info.clipStart ?? 0
    let end = info.clipEnd
    let destination = clipDestination(for: url, start: start, end: end ?? info.videoDuration?.second ?? 0)
    info.isExportingClip = true
    log("Exporting clip \(start)-\(end.map { String($0) } ?? "end") to \(destination.path)")
    sendOSD(.clipExporting(0), autoHide: false)

    DispatchQueue.global(qos: .userInitiated).async { [self] in
      let result: Result<URL, Error>
      do {
        let clipURL = try ClipExporter.exportClip(from: url, to: destination, start: start, end: end ?? -1) { [self] fraction in
          DispatchQueue.main.async { [self] in
            sendOSD(.clipExporting(fraction), autoHide: false)
          }
        }
        result = .success(clipURL)
      } catch {
        result = .failure(error)
      }
      DispatchQueue.main.async { [self] in
        info.isExportingClip = false
        switch result {
        case .success(let clipURL):
          log("Clip saved to \(clipURL.path)")
          sendOSD(.clipExported(clipURL.lastPathComponent))
          // The selection has been saved, unless another file is playing by now.
          if info.currentURL == url {
            clearClipSelection(showOSD: false)
          }
        case .failure(let error):
          log("Failed to export clip: \(error.localizedDescription)", level: .error)
          sendOSD(.clipExportFailed(error.localizedDescription))
        }
      }
    }
  }

  // MARK: - Private

  /// Redraws the play slider, which shows the selection.
  private func clipSelectionChanged() {
    guard mainWindow.loaded else { return }
    mainWindow.playSlider.needsDisplay = true
  }

  /// Formats a time the way the time labels of the on screen controller do.
  private func clipTimeString(_ seconds: Double) -> String {
    VideoTime(seconds).stringRepresentationWithPrecision(DurationDisplayTextField.precision)
  }

  /// Returns where to save a clip of the given file: next to it, or in the Movies folder if its folder cannot be written to.
  ///
  /// The name of the clip is the name of the original followed by the times of the clip, such as `Movie [00.01.23-00.02.34].mkv`.
  private func clipDestination(for url: URL, start: Double, end: Double) -> URL {
    var folder = url.deletingLastPathComponent()
    if !FileManager.default.isWritableFile(atPath: folder.path),
       let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first {
      folder = movies
    }
    let name = url.deletingPathExtension().lastPathComponent
    let pathExtension = url.pathExtension.isEmpty ? "mkv" : url.pathExtension
    let fileName = "\(name) [\(clipFileNameTime(start))-\(clipFileNameTime(end))].\(pathExtension)"
    return ClipExporter.availableURL(for: folder.appendingPathComponent(fileName))
  }

  /// Formats a time for a file name as `hh.mm.ss`, the Finder not allowing colons in file names.
  private func clipFileNameTime(_ seconds: Double) -> String {
    let total = max(0, Int(seconds))
    return String(format: "%02d.%02d.%02d", total / 3600, total % 3600 / 60, total % 60)
  }
}
