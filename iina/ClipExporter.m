//
//  ClipExporter.m
//  iina
//
//  Created by grafmik on 19/9/2026.
//  Copyright © 2026 lhc. All rights reserved.
//

#import "ClipExporter.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"
#import <libavcodec/avcodec.h>
#import <libavformat/avformat.h>
#pragma clang diagnostic pop

#import "IINA-Swift.h"

#define LOG_DEBUG(msg, ...) [FFmpegLogger debug:([NSString stringWithFormat:(msg), ##__VA_ARGS__])];
#define LOG_ERROR(msg, ...) [FFmpegLogger error:([NSString stringWithFormat:(msg), ##__VA_ARGS__])];
#define LOG_WARN(msg, ...) [FFmpegLogger warn:([NSString stringWithFormat:(msg), ##__VA_ARGS__])];

static NSString * const ClipExporterErrorDomain = @"ClipExporterErrorDomain";

/// Returns the translation of the given key, or the given English text for languages without a translation.
static NSString *localized(NSString *key, NSString *english) {
  return [NSBundle.mainBundle localizedStringForKey:key value:english table:nil];
}

/// `YES` if the given muxer writes Matroska, the container used when the original one cannot hold the copied streams.
static BOOL isMatroska(const AVOutputFormat *format) {
  return strcmp(format->name, "matroska") == 0;
}

/// `YES` if the given muxer belongs to the MP4 family.
///
/// These muxers accept negative timestamps and turn them into an edit list, which lets players skip the frames that precede the
/// start of the clip.
static BOOL isQuickTime(const AVOutputFormat *format) {
  static const char *names[] = {"mp4", "mov", "ipod", "3gp", "3g2", "psp", "f4v", "ismv"};
  for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
    if (strcmp(format->name, names[i]) == 0) { return YES; }
  }
  return NO;
}

/// Finds the last keyframe of a video stream at or before the given time.
///
/// With most demuxers seeking lands on the keyframe preceding the requested time, but not always: with MPEG-TS for instance it can
/// land after it. Earlier and earlier times are tried until a keyframe preceding the given time is found.
/// - Parameters:
///   - time: Time in `AV_TIME_BASE` units.
///   - seekTime: Set to the time, in `AV_TIME_BASE` units, to seek to in order to read the stream from the keyframe.
/// - Returns: The presentation time of the keyframe in `AV_TIME_BASE` units. When there is no keyframe before the given time, the time
///     of the first keyframe found after it. `AV_NOPTS_VALUE` if no keyframe was found.
static int64_t findKeyframeBefore(AVFormatContext *context, int videoIndex, int64_t time, int64_t fileStart, AVPacket *packet,
                                  int64_t *seekTime)
{
  const AVRational timeBase = context->streams[videoIndex]->time_base;
  int64_t margin = 0;
  while (YES) {
    const int64_t target = MAX(time - margin, fileStart);
    if (avformat_seek_file(context, -1, INT64_MIN, target, target, 0) < 0) { return AV_NOPTS_VALUE; }
    int64_t firstKeyframe = AV_NOPTS_VALUE;
    int64_t lastKeyframe = AV_NOPTS_VALUE;
    // Read the video until past the given time. Keyframes are rarely more than a few seconds apart, so give up after a while.
    for (int count = 0; count < 20000 && av_read_frame(context, packet) >= 0; count++) {
      const BOOL isVideo = packet->stream_index == videoIndex;
      const BOOL isKeyframe = (packet->flags & AV_PKT_FLAG_KEY) != 0;
      const int64_t pts = packet->pts != AV_NOPTS_VALUE ? packet->pts : packet->dts;
      const int64_t dts = packet->dts != AV_NOPTS_VALUE ? packet->dts : packet->pts;
      av_packet_unref(packet);
      if (!isVideo || pts == AV_NOPTS_VALUE) { continue; }
      if (isKeyframe) {
        const int64_t keyframeTime = av_rescale_q(pts, timeBase, AV_TIME_BASE_Q);
        if (firstKeyframe == AV_NOPTS_VALUE) { firstKeyframe = keyframeTime; }
        if (keyframeTime <= time) { lastKeyframe = keyframeTime; }
      }
      if (firstKeyframe != AV_NOPTS_VALUE && av_rescale_q(dts, timeBase, AV_TIME_BASE_Q) > time) { break; }
    }
    if (lastKeyframe != AV_NOPTS_VALUE || firstKeyframe == AV_NOPTS_VALUE || target == fileStart
        || margin >= 64 * AV_TIME_BASE) {
      *seekTime = target;
      return lastKeyframe != AV_NOPTS_VALUE ? lastKeyframe : firstKeyframe;
    }
    margin = margin == 0 ? AV_TIME_BASE : margin * 2;
  }
}

/// Copies the packets of the given time range of the input file into the output file.
/// - Parameters:
///   - muxerFailed: Set to `YES` when the failure comes from the container of the output file, in which case another container
///       might work.
///   - message: Set to a localized description of the problem on failure.
/// - Returns: Zero on success, a negative FFmpeg error code otherwise.
static int remuxClip(NSURL *inputURL, NSURL *outputURL, const AVOutputFormat *format, double start, double end,
                     void (^progress)(double), BOOL *muxerFailed, NSString **message)
{
  AVFormatContext *inputContext = NULL;
  AVFormatContext *outputContext = NULL;
  AVPacket *packet = NULL;
  int *streamMapping = NULL;
  BOOL *streamStarted = NULL;
  BOOL *streamEnded = NULL;
  *muxerFailed = NO;

  @try {
    int ret = avformat_open_input(&inputContext, inputURL.fileSystemRepresentation, NULL, NULL);
    if (ret >= 0) {
      ret = avformat_find_stream_info(inputContext, NULL);
    }
    if (ret < 0) {
      LOG_ERROR(@"Cannot open %@ to export a clip: %s (%d)", inputURL.path, av_err2str(ret), ret);
      *message = localized(@"clip.error.open", @"The file cannot be read");
      return ret;
    }

    ret = avformat_alloc_output_context2(&outputContext, format, NULL, outputURL.fileSystemRepresentation);
    if (ret < 0 || !outputContext) {
      LOG_ERROR(@"Cannot create the %s muxer: %s (%d)", format->name, av_err2str(ret), ret);
      *message = localized(@"clip.error.write", @"The clip cannot be written");
      return ret < 0 ? ret : AVERROR(ENOMEM);
    }

    const unsigned int streamCount = inputContext->nb_streams;
    streamMapping = av_calloc(streamCount, sizeof(*streamMapping));
    streamStarted = av_calloc(streamCount, sizeof(*streamStarted));
    streamEnded = av_calloc(streamCount, sizeof(*streamEnded));
    packet = av_packet_alloc();
    if (!streamMapping || !streamStarted || !streamEnded || !packet) {
      *message = localized(@"clip.error.write", @"The clip cannot be written");
      return AVERROR(ENOMEM);
    }

    // Choose the streams to copy. Video and audio streams are required: when the container cannot hold one of them the export fails
    // so that it can be retried with Matroska. Subtitles and attachments the container cannot hold are left out. Cover art and data
    // streams, such as timecodes, are not copied.
    int mainStreamCount = 0;
    for (unsigned int i = 0; i < streamCount; i++) {
      streamMapping[i] = -1;
      AVStream *inputStream = inputContext->streams[i];
      AVCodecParameters *parameters = inputStream->codecpar;
      const enum AVMediaType type = parameters->codec_type;
      if (inputStream->disposition & (AV_DISPOSITION_ATTACHED_PIC | AV_DISPOSITION_TIMED_THUMBNAILS)) { continue; }
      if (parameters->codec_id == AV_CODEC_ID_NONE) { continue; }
      const BOOL isMain = type == AVMEDIA_TYPE_VIDEO || type == AVMEDIA_TYPE_AUDIO;
      if (type == AVMEDIA_TYPE_ATTACHMENT) {
        // Fonts used by styled subtitles. Matroska stores them using their MIME type rather than a codec.
        if (!isMatroska(format)) { continue; }
      } else if (!isMain && type != AVMEDIA_TYPE_SUBTITLE) {
        continue;
      } else if (avformat_query_codec(format, parameters->codec_id, FF_COMPLIANCE_NORMAL) == 0) {
        if (isMain) {
          LOG_WARN(@"The %s muxer cannot hold %s", format->name, avcodec_get_name(parameters->codec_id));
          *muxerFailed = YES;
          *message = localized(@"clip.error.write", @"The clip cannot be written");
          return AVERROR(EINVAL);
        }
        LOG_DEBUG(@"Leaving out stream %u, the %s muxer cannot hold %s", i, format->name,
                  avcodec_get_name(parameters->codec_id));
        continue;
      }

      AVStream *outputStream = avformat_new_stream(outputContext, NULL);
      if (!outputStream) {
        *message = localized(@"clip.error.write", @"The clip cannot be written");
        return AVERROR(ENOMEM);
      }
      ret = avcodec_parameters_copy(outputStream->codecpar, parameters);
      if (ret < 0) {
        *message = localized(@"clip.error.write", @"The clip cannot be written");
        return ret;
      }
      // Keep the codec tag of the original when the container accepts it, as the ffmpeg command line tool does. This keeps for
      // instance the hvc1 tag QuickTime requires for HEVC.
      unsigned int codecTag = 0;
      unsigned int defaultTag;
      if (!format->codec_tag
          || av_codec_get_id(format->codec_tag, parameters->codec_tag) == parameters->codec_id
          || !av_codec_get_tag2(format->codec_tag, parameters->codec_id, &defaultTag)) {
        codecTag = parameters->codec_tag;
      }
      outputStream->codecpar->codec_tag = codecTag;
      outputStream->time_base = inputStream->time_base;
      outputStream->avg_frame_rate = inputStream->avg_frame_rate;
      outputStream->disposition = inputStream->disposition;
      av_dict_copy(&outputStream->metadata, inputStream->metadata, 0);
      streamMapping[i] = outputStream->index;
      if (isMain) { mainStreamCount++; }
    }
    int videoIndex = -1;
    for (unsigned int i = 0; i < streamCount && videoIndex < 0; i++) {
      if (streamMapping[i] >= 0 && inputContext->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
        videoIndex = (int)i;
      }
    }
    if (mainStreamCount == 0) {
      LOG_ERROR(@"No video or audio stream to copy in %@", inputURL.path);
      *message = localized(@"clip.error.no_stream", @"The file has no video or audio stream that can be copied");
      return AVERROR_STREAM_NOT_FOUND;
    }
    av_dict_copy(&outputContext->metadata, inputContext->metadata, 0);

    // The frames between the keyframe preceding the start and the start get negative timestamps. The MP4 family keeps them and
    // writes an edit list so players skip those frames. The other containers get timestamps starting at zero.
    if (!isQuickTime(format)) {
      outputContext->avoid_negative_ts = AVFMT_AVOID_NEG_TS_MAKE_ZERO;
    }

    if (!(format->flags & AVFMT_NOFILE)) {
      ret = avio_open(&outputContext->pb, outputURL.fileSystemRepresentation, AVIO_FLAG_WRITE);
      if (ret < 0) {
        LOG_ERROR(@"Cannot create %@: %s (%d)", outputURL.path, av_err2str(ret), ret);
        *message = localized(@"clip.error.create", @"The clip file cannot be created");
        return ret;
      }
    }
    AVDictionary *options = NULL;
    if (isQuickTime(format)) {
      // Put the index at the beginning of the file so the clip can be played while being downloaded.
      av_dict_set(&options, "movflags", "+faststart", 0);
    }
    ret = avformat_write_header(outputContext, &options);
    av_dict_free(&options);
    if (ret < 0) {
      LOG_ERROR(@"Cannot write the header of %@: %s (%d)", outputURL.path, av_err2str(ret), ret);
      *muxerFailed = YES;
      *message = localized(@"clip.error.write", @"The clip cannot be written");
      return ret;
    }

    // mpv reports times from the start of the file, while packets carry the timestamps of the container.
    const int64_t fileStart = inputContext->start_time != AV_NOPTS_VALUE ? inputContext->start_time : 0;
    const int64_t startTime = fileStart + llround(MAX(start, 0) * AV_TIME_BASE);
    const int64_t endTime = end >= 0 ? fileStart + llround(end * AV_TIME_BASE) : INT64_MAX;

    // Time of the keyframe the video starts from, and time at which audio and subtitles start, which becomes zero in the clip.
    int64_t keyframeTime = AV_NOPTS_VALUE;
    int64_t cutTime = startTime;
    if (start > 0) {
      int64_t seekTime = startTime;
      if (videoIndex >= 0) {
        keyframeTime = findKeyframeBefore(inputContext, videoIndex, startTime, fileStart, packet, &seekTime);
      }
      // Without an edit list the frames preceding the start are shown, so the clip starts at the keyframe along with the sound.
      if (!isQuickTime(format) && keyframeTime != AV_NOPTS_VALUE && keyframeTime < startTime) {
        cutTime = keyframeTime;
      }
      ret = avformat_seek_file(inputContext, -1, INT64_MIN, seekTime, seekTime, 0);
      if (ret < 0) {
        LOG_ERROR(@"Cannot seek to %f in %@: %s (%d)", start, inputURL.path, av_err2str(ret), ret);
        *message = localized(@"clip.error.open", @"The file cannot be read");
        return ret;
      }
    }
    int64_t progressEnd = endTime;
    if (progressEnd == INT64_MAX) {
      progressEnd = inputContext->duration > 0 ? fileStart + inputContext->duration : AV_NOPTS_VALUE;
    }

    int endedMainStreamCount = 0;
    // Whether video or audio of the selection itself, not only frames preceding it, has been written.
    BOOL wroteSelection = NO;
    double reportedProgress = 0;
    while (endedMainStreamCount < mainStreamCount) {
      ret = av_read_frame(inputContext, packet);
      if (ret == AVERROR_EOF) { break; }
      if (ret < 0) {
        LOG_ERROR(@"Cannot read %@: %s (%d)", inputURL.path, av_err2str(ret), ret);
        *message = localized(@"clip.error.open", @"The file cannot be read");
        return ret;
      }
      const int index = packet->stream_index;
      if (index < 0 || (unsigned int)index >= streamCount || streamMapping[index] < 0 || streamEnded[index]) {
        av_packet_unref(packet);
        continue;
      }
      AVStream *inputStream = inputContext->streams[index];
      AVStream *outputStream = outputContext->streams[streamMapping[index]];
      const enum AVMediaType type = inputStream->codecpar->codec_type;
      const BOOL isMain = type == AVMEDIA_TYPE_VIDEO || type == AVMEDIA_TYPE_AUDIO;
      const int64_t cut = av_rescale_q(cutTime, AV_TIME_BASE_Q, inputStream->time_base);

      // Packets are read in decoding order, so the decoding timestamp tells when a stream is past the end of the clip.
      const int64_t timestamp = packet->dts != AV_NOPTS_VALUE ? packet->dts : packet->pts;
      const int64_t time = timestamp != AV_NOPTS_VALUE ?
          av_rescale_q(timestamp, inputStream->time_base, AV_TIME_BASE_Q) : AV_NOPTS_VALUE;
      if (time != AV_NOPTS_VALUE && time >= endTime) {
        streamEnded[index] = YES;
        if (isMain) { endedMainStreamCount++; }
        av_packet_unref(packet);
        continue;
      }

      if (type == AVMEDIA_TYPE_VIDEO) {
        // Video can only be decoded from a keyframe, it starts with the one found before the start.
        if (!streamStarted[index]) {
          const BOOL isBeforeKeyframe = index == videoIndex && keyframeTime != AV_NOPTS_VALUE && packet->pts != AV_NOPTS_VALUE
              && av_rescale_q(packet->pts, inputStream->time_base, AV_TIME_BASE_Q) < keyframeTime;
          if (!(packet->flags & AV_PKT_FLAG_KEY) || isBeforeKeyframe) {
            av_packet_unref(packet);
            continue;
          }
        }
      } else if (packet->pts != AV_NOPTS_VALUE && packet->pts < cut) {
        // Audio and subtitles are cut: drop what ends before the cut.
        if (packet->pts + MAX(packet->duration, 0) <= cut) {
          av_packet_unref(packet);
          continue;
        }
        if (type == AVMEDIA_TYPE_SUBTITLE) {
          // A subtitle already on screen at the cut is shown from the beginning of the clip.
          packet->duration -= cut - packet->pts;
          packet->pts = cut;
          packet->dts = cut;
        }
      }
      streamStarted[index] = YES;

      if (progress && isMain && time != AV_NOPTS_VALUE && progressEnd != AV_NOPTS_VALUE && progressEnd > cutTime) {
        const double fraction = MIN(MAX((double)(time - cutTime) / (double)(progressEnd - cutTime), 0), 1);
        if (fraction - reportedProgress >= 0.01) {
          reportedProgress = fraction;
          progress(fraction);
        }
      }

      if (isMain && packet->pts != AV_NOPTS_VALUE
          && av_rescale_q(packet->pts + MAX(packet->duration, 0), inputStream->time_base, AV_TIME_BASE_Q) > startTime) {
        wroteSelection = YES;
      }

      // Make the clip start at zero.
      if (packet->pts != AV_NOPTS_VALUE) { packet->pts -= cut; }
      if (packet->dts != AV_NOPTS_VALUE) { packet->dts -= cut; }
      av_packet_rescale_ts(packet, inputStream->time_base, outputStream->time_base);
      packet->stream_index = outputStream->index;
      packet->pos = -1;
      ret = av_interleaved_write_frame(outputContext, packet);
      if (ret < 0) {
        LOG_ERROR(@"Cannot write a packet to %@: %s (%d)", outputURL.path, av_err2str(ret), ret);
        *muxerFailed = YES;
        *message = localized(@"clip.error.write", @"The clip cannot be written");
        return ret;
      }
    }

    if (!wroteSelection) {
      LOG_ERROR(@"Nothing to copy between %f and %f in %@", start, end, inputURL.path);
      *message = localized(@"clip.error.empty", @"The selection contains nothing to copy");
      return AVERROR_INVALIDDATA;
    }
    ret = av_write_trailer(outputContext);
    if (ret < 0) {
      LOG_ERROR(@"Cannot finish writing %@: %s (%d)", outputURL.path, av_err2str(ret), ret);
      *muxerFailed = YES;
      *message = localized(@"clip.error.write", @"The clip cannot be written");
      return ret;
    }
    return 0;
  }
  @finally {
    av_packet_free(&packet);
    av_freep(&streamMapping);
    av_freep(&streamStarted);
    av_freep(&streamEnded);
    avformat_close_input(&inputContext);
    if (outputContext) {
      if (!(outputContext->oformat->flags & AVFMT_NOFILE)) {
        avio_closep(&outputContext->pb);
      }
      avformat_free_context(outputContext);
    }
  }
}

@implementation ClipExporter

+ (NSURL *)availableURLForURL:(NSURL *)url
{
  NSFileManager *fileManager = NSFileManager.defaultManager;
  if (![fileManager fileExistsAtPath:url.path]) { return url; }
  NSString *extension = url.pathExtension;
  NSString *name = url.URLByDeletingPathExtension.lastPathComponent;
  NSURL *folder = url.URLByDeletingLastPathComponent;
  for (NSInteger counter = 2; ; counter++) {
    NSURL *candidate = [folder URLByAppendingPathComponent:[NSString stringWithFormat:@"%@ %ld", name, (long)counter]];
    if (extension.length > 0) {
      candidate = [candidate URLByAppendingPathExtension:extension];
    }
    if (![fileManager fileExistsAtPath:candidate.path]) { return candidate; }
  }
}

/// Writes the clip to a temporary file next to the destination, then gives it its final name once complete.
+ (int)writeClipFromURL:(NSURL *)inputURL
                  toURL:(NSURL *)destination
                 format:(const AVOutputFormat *)format
                  start:(double)start
                    end:(double)end
               progress:(void (^)(double))progress
            muxerFailed:(BOOL *)muxerFailed
                message:(NSString **)message
{
  NSURL *partialURL = [destination URLByAppendingPathExtension:@"part"];
  LOG_DEBUG(@"Writing clip %f-%f of %@ to %@ using the %s muxer", start, end, inputURL.path, partialURL.path, format->name);
  int ret = remuxClip(inputURL, partialURL, format, start, end, progress, muxerFailed, message);
  NSFileManager *fileManager = NSFileManager.defaultManager;
  if (ret >= 0) {
    NSError *moveError = nil;
    if (![fileManager moveItemAtURL:partialURL toURL:destination error:&moveError]) {
      LOG_ERROR(@"Cannot rename %@ to %@: %@", partialURL.path, destination.lastPathComponent, moveError);
      *message = moveError.localizedDescription;
      ret = AVERROR(EIO);
    }
  }
  if (ret < 0) {
    [fileManager removeItemAtURL:partialURL error:nil];
  }
  return ret;
}

+ (NSURL *)exportClipFromURL:(NSURL *)inputURL
                       toURL:(NSURL *)outputURL
                       start:(double)start
                         end:(double)end
                    progress:(void (^)(double))progress
                       error:(NSError **)error
{
  const AVOutputFormat *matroska = av_guess_format("matroska", NULL, NULL);
  NSURL *destination = outputURL;
  const AVOutputFormat *format = av_guess_format(NULL, outputURL.fileSystemRepresentation, NULL);
  if (!format) {
    LOG_WARN(@"No muxer for the extension of %@, using Matroska", outputURL.lastPathComponent);
    format = matroska;
    destination = [self availableURLForURL:[outputURL.URLByDeletingPathExtension URLByAppendingPathExtension:@"mkv"]];
  }

  BOOL muxerFailed = NO;
  NSString *message = nil;
  int ret = [self writeClipFromURL:inputURL toURL:destination format:format start:start end:end progress:progress
                       muxerFailed:&muxerFailed message:&message];
  if (ret < 0 && muxerFailed && !isMatroska(format)) {
    LOG_WARN(@"The %s container cannot hold the clip, retrying with Matroska", format->name);
    destination = [self availableURLForURL:[outputURL.URLByDeletingPathExtension URLByAppendingPathExtension:@"mkv"]];
    ret = [self writeClipFromURL:inputURL toURL:destination format:matroska start:start end:end progress:progress
                     muxerFailed:&muxerFailed message:&message];
  }
  if (ret < 0) {
    if (error) {
      *error = [NSError errorWithDomain:ClipExporterErrorDomain code:ret
                               userInfo:@{NSLocalizedDescriptionKey: message ?: @""}];
    }
    return nil;
  }
  LOG_DEBUG(@"Clip written to %@", destination.path);
  return destination;
}

@end
