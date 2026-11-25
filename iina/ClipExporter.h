//
//  ClipExporter.h
//  iina
//
//  Created by grafmik on 19/9/2026.
//  Copyright © 2026 lhc. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Exports a section of a media file to a new file without re-encoding it.
///
/// The packets of the video, audio and subtitle streams are copied as they are (remuxed), so the clip keeps exactly the quality and
/// the codecs of the original. The container of the original is kept when it can hold all the copied streams, otherwise Matroska is
/// used.
/// - Note: As the video is not re-encoded a clip can only start on a keyframe, so the frames between the keyframe preceding the start
///       and the start are copied as well. MP4 and QuickTime files get an edit list telling players to skip those frames, other
///       containers show them.
@interface ClipExporter : NSObject

/// Returns the given URL if no file exists at this location, otherwise the first free URL obtained by appending a counter to the file
/// name, such as `name 2.mp4`.
+ (NSURL *)availableURLForURL:(NSURL *)url NS_SWIFT_NAME(availableURL(for:));

/// Copies the part of a file between the given times into a new file.
///
/// This method blocks until the clip is written, it must not be called from the main thread.
/// - Parameters:
///   - inputURL: URL of the local file to read.
///   - outputURL: Wanted location of the clip. Its extension selects the container.
///   - start: Start of the clip in seconds, as reported by the mpv `time-pos` property. Zero starts the clip at the beginning of the
///       file.
///   - end: End of the clip in seconds, as reported by the mpv `time-pos` property. A negative value ends the clip at the end of the
///       file.
///   - progress: Block called from the exporting thread with the fraction of the clip written so far.
///   - error: Set to an error describing the problem when the export fails.
/// - Returns: The location of the clip, which only differs from `outputURL` when Matroska had to be used, or `nil` if the export failed.
+ (nullable NSURL *)exportClipFromURL:(NSURL *)inputURL
                                toURL:(NSURL *)outputURL
                                start:(double)start
                                  end:(double)end
                             progress:(nullable void (^)(double fraction))progress
                                error:(NSError **)error NS_SWIFT_NAME(exportClip(from:to:start:end:progress:));

/// Saves the part of a file between the given times as an MP4 file that can be shared, in a messaging app for instance.
///
/// Unlike `exportClip(from:to:start:end:progress:)` the clip is encoded again: H.264 video, scaled down to fit in 1920×1080, and
/// AAC audio in stereo, which nearly every device and app can play. It starts and ends on the exact frames. The subtitles are drawn
/// on the video, as messaging apps do not show subtitle tracks. Only text subtitles can be drawn, not picture-based ones.
///
/// This method blocks until the clip is written, it must not be called from the main thread.
/// - Parameters:
///   - inputURL: URL of the local file to read.
///   - outputURL: Location of the clip.
///   - start: Start of the clip in seconds, as reported by the mpv `time-pos` property.
///   - end: End of the clip in seconds, as reported by the mpv `time-pos` property. A negative value ends the clip at the end of the
///       file.
///   - videoStream: Index of the video stream of the file to use, as reported by the mpv `ff-index` track property. A negative
///       or invalid value uses the main video stream.
///   - audioStream: Index of the audio stream of the file to use. A negative or invalid value uses the main audio stream.
///   - subtitlesURL: File holding the subtitles to draw: `inputURL` for subtitles stored in the file, or a subtitle file. `nil` for
///       no subtitles.
///   - subtitlesStream: Index of the subtitle stream of `inputURL` to draw. Ignored for subtitle files.
///   - progress: Block called from the exporting thread with the fraction of the clip written so far.
///   - burnedSubtitles: Set to `YES` if subtitles were drawn on the video. They are left out when they cannot be drawn.
///   - error: Set to an error describing the problem when the export fails.
/// - Returns: The location of the clip, or `nil` if the export failed.
+ (nullable NSURL *)exportShareableClipFromURL:(NSURL *)inputURL
                                         toURL:(NSURL *)outputURL
                                         start:(double)start
                                           end:(double)end
                                   videoStream:(NSInteger)videoStream
                                   audioStream:(NSInteger)audioStream
                                  subtitlesURL:(nullable NSURL *)subtitlesURL
                               subtitlesStream:(NSInteger)subtitlesStream
                                      progress:(nullable void (^)(double fraction))progress
                               burnedSubtitles:(nullable BOOL *)burnedSubtitles
                                         error:(NSError **)error
    NS_SWIFT_NAME(exportShareableClip(from:to:start:end:videoStream:audioStream:subtitlesURL:subtitlesStream:progress:burnedSubtitles:));

@end

NS_ASSUME_NONNULL_END
