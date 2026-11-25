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
/// Exporting copies the streams of the selected part into a new file placed next to the original, see `ClipExporter`. Exporting for
/// sharing encodes them again into an MP4 file messaging apps can play, with the subtitles drawn on the video.
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

  /// Saves the selected clip next to the original file.
  ///
  /// The export runs in the background with its progress shown in the OSD. Once the clip is saved the selection is cleared.
  /// - Parameter forSharing: `False` to keep the quality and the codecs of the original. `True` to encode the clip again as an MP4
  ///     file in H.264 and AAC that messaging apps such as Telegram can play, with the subtitles of the file drawn on the video.
  func exportClip(forSharing: Bool = false) {
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
    let hasVideo = info.videoTracks.contains { !$0.isAlbumart }
    let pathExtension = forSharing ? (hasVideo ? "mp4" : "m4a") : nil
    let destination = clipDestination(for: url, start: start, end: end ?? info.videoDuration?.second ?? 0,
                                      pathExtension: pathExtension)
    // Tracks chosen in the player, read now on the main thread.
    let videoStream = selectedStreamIndex(of: info.videoTracks, id: info.vid)
    let audioStream = selectedStreamIndex(of: info.audioTracks, id: info.aid)
    let subtitles = forSharing && hasVideo ? clipSubtitles(of: url) : nil
    info.isExportingClip = true
    log("Exporting clip \(start)-\(end.map { String($0) } ?? "end") to \(destination.path)"
        + (forSharing ? " for sharing, subtitles: \(subtitles.map { "\($0.url.path) #\($0.stream)" } ?? "none")" : ""))
    let progressMessage: (Double) -> OSDMessage = forSharing ? { .clipExportingForSharing($0) } : { .clipExporting($0) }
    sendOSD(progressMessage(0), autoHide: false)

    DispatchQueue.global(qos: .userInitiated).async { [self] in
      let result: Result<URL, Error>
      let progress: (Double) -> Void = { [self] fraction in
        DispatchQueue.main.async { [self] in
          sendOSD(progressMessage(fraction), autoHide: false)
        }
      }
      do {
        let clipURL: URL
        if forSharing {
          var burnedSubtitles: ObjCBool = false
          clipURL = try ClipExporter.exportShareableClip(from: url, to: destination, start: start, end: end ?? -1,
                                                         videoStream: videoStream, audioStream: audioStream,
                                                         subtitlesURL: subtitles?.url, subtitlesStream: subtitles?.stream ?? -1,
                                                         progress: progress, burnedSubtitles: &burnedSubtitles)
          if subtitles != nil && !burnedSubtitles.boolValue {
            log("The subtitles could not be drawn on the clip", level: .warning)
          }
        } else {
          clipURL = try ClipExporter.exportClip(from: url, to: destination, start: start, end: end ?? -1, progress: progress)
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
          // Name the folder as well: the clip is saved next to the original, which is not always where one looks first.
          let folderName = clipURL.deletingLastPathComponent().lastPathComponent
          sendOSD(.clipExported("\(folderName)/\(clipURL.lastPathComponent)"))
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

  /// Returns the FFmpeg index of the selected track of the given list, or -1 to let the exporter choose.
  private func selectedStreamIndex(of tracks: [MPVTrack], id: Int?) -> Int {
    guard let id, let track = tracks.first(where: { $0.id == id }), !track.isExternal else { return -1 }
    return track.ffIndex ?? -1
  }

  /// Finds the subtitles to draw on a clip saved for sharing, even if none are shown: the subtitles shown first, then the subtitles
  /// of the file or loaded with it, preferring full subtitles to forced ones.
  ///
  /// Picture-based subtitles, as found on Blu-ray and DVD, cannot be drawn by the exporter and are skipped.
  /// - Returns: The file holding the subtitles, which is `url` for subtitles stored in the file, along with the FFmpeg index of their
  ///     stream in it, or `nil` if there are no subtitles to draw.
  private func clipSubtitles(of url: URL) -> (url: URL, stream: Int)? {
    let pictureCodecs: Set<String> = ["hdmv_pgs_subtitle", "dvb_subtitle", "dvd_subtitle", "xsub"]
    let tracks = info.$subTracks.withLock { $0 }.filter { !pictureCodecs.contains($0.codec ?? "") }
    let selected = [info.sid, info.secondSid].compactMap { id in tracks.first { $0.id == id } }
    for track in selected + tracks.filter({ !$0.isForced }) + tracks.filter({ $0.isForced }) {
      if track.isExternal {
        guard let filename = track.externalFilename else { continue }
        let subtitlesURL = filename.hasPrefix("/") ? URL(fileURLWithPath: filename) : URL(string: filename)
        if let subtitlesURL, subtitlesURL.isFileURL, FileManager.default.fileExists(atPath: subtitlesURL.path) {
          return (subtitlesURL, -1)
        }
      } else if let stream = track.ffIndex {
        return (url, stream)
      }
    }
    return nil
  }

  /// Returns where to save a clip of the given file: next to it, or in the Movies folder if its folder cannot be written to.
  ///
  /// The name of the clip is the name of the original followed by the times of the clip, such as `Movie [00.01.23-00.02.34].mkv`.
  /// - Parameter pathExtension: Extension of the clip, `nil` for the extension of the original.
  private func clipDestination(for url: URL, start: Double, end: Double, pathExtension: String? = nil) -> URL {
    var folder = url.deletingLastPathComponent()
    if !FileManager.default.isWritableFile(atPath: folder.path),
       let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first {
      folder = movies
    }
    let name = url.deletingPathExtension().lastPathComponent
    let pathExtension = pathExtension ?? (url.pathExtension.isEmpty ? "mkv" : url.pathExtension)
    let fileName = "\(name) [\(clipFileNameTime(start))-\(clipFileNameTime(end))].\(pathExtension)"
    return ClipExporter.availableURL(for: folder.appendingPathComponent(fileName))
  }

  /// Formats a time for a file name as `hh.mm.ss`, the Finder not allowing colons in file names.
  private func clipFileNameTime(_ seconds: Double) -> String {
    let total = max(0, Int(seconds))
    return String(format: "%02d.%02d.%02d", total / 3600, total % 3600 / 60, total % 60)
  }
}
