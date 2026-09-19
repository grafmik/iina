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

@end

NS_ASSUME_NONNULL_END
