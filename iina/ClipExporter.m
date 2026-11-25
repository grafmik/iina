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
#import <libavfilter/avfilter.h>
#import <libavfilter/buffersink.h>
#import <libavfilter/buffersrc.h>
#import <libavformat/avformat.h>
#import <libavutil/channel_layout.h>
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

/// Seeks to the given time, in `AV_TIME_BASE` units, landing on or before it.
///
/// Seeking to the start of the file goes back to its first byte when the demuxer allows it: with MPEG-TS for instance seeking to
/// the start time can land just after the first keyframe, leaving no keyframe to decode the video from until the next one.
static int seekToTime(AVFormatContext *context, int64_t time, int64_t fileStart) {
  if (time <= fileStart && !(context->iformat->flags & AVFMT_NO_BYTE_SEEK)
      && avformat_seek_file(context, -1, 0, 0, 0, AVSEEK_FLAG_BYTE) >= 0) {
    return 0;
  }
  return avformat_seek_file(context, -1, INT64_MIN, time, time, 0);
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
    if (seekToTime(context, target, fileStart) < 0) { return AV_NOPTS_VALUE; }
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
      ret = seekToTime(inputContext, seekTime, fileStart);
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

#pragma mark - Clips for sharing

/// Largest size of the video of a clip saved for sharing, in pixels: larger videos are scaled down to fit in 1920×1080, or 1080×1920.
static const int ShareMaxLongSide = 1920;
static const int ShareMaxShortSide = 1080;

/// Video and audio are read this long after the end of the clip, so that frames shown out of order are not missed.
static const int64_t ShareReadMargin = 2 * AV_TIME_BASE;

/// Subtitles shown before the start of the clip are looked for this long before it, as they may still be on screen.
static const int64_t ShareSubtitlesLookBehind = 30 * AV_TIME_BASE;

/// A stream of the original decoded, filtered and encoded again into a clip saved for sharing.
typedef struct {
  /// Index of the stream in the original, -1 when the clip has no such stream.
  int inputIndex;
  AVStream *inputStream;
  AVCodecContext *decoder;
  /// Created with the encoder when the first frame is decoded, as the decoder only then tells the format of the frames.
  AVFilterGraph *graph;
  AVFilterContext *source;
  AVFilterContext *sink;
  AVCodecContext *encoder;
  AVStream *outputStream;
  /// No more packets are sent to the decoder.
  BOOL inputEnded;
  /// The filters let no more frames through, the end of the clip has been reached.
  BOOL filterEnded;
  /// Timestamp of the next audio frame in the time base of the encoder.
  int64_t nextPts;
} ShareStream;

/// Everything about a clip being saved for sharing.
typedef struct {
  AVFormatContext *input;
  AVFormatContext *output;
  NSURL *outputURL;
  ShareStream video;
  ShareStream audio;
  AVFrame *frame;
  AVFrame *filteredFrame;
  AVPacket *encodedPacket;
  /// Packets encoded before the header of the clip could be written, which requires every encoder to be open.
  AVPacket **pendingPackets;
  int pendingCount;
  BOOL headerWritten;
  BOOL wroteFrames;
  /// Times in seconds, on the clock of the timestamps of the original. The cut time becomes zero in the clip. Negative values for
  /// trimming mean no trimming.
  double cutTime;
  double trimStart;
  double trimEnd;
  /// Duration of the clip in seconds, used for the progress. Zero or less if not known.
  double duration;
  double reportedProgress;
  void (^progress)(double);
  /// File of the subtitles drawn on the video, `nil` for none.
  NSString *subtitlesPath;
  /// Index of the subtitles among the subtitle streams of their file, -1 for the first one.
  int subtitlesIndex;
  /// Character encoding of a subtitle file not encoded in UTF-8, `nil` otherwise.
  NSString *subtitlesCharset;
  /// Seconds subtracted from the timestamps of the video before drawing the subtitles: subtitle files count from the start of the
  /// file, while the timestamps of some containers do not start at zero.
  double subtitlesOffset;
  BOOL burnedSubtitles;
  NSString *message;
} ShareJob;

/// Converts strings into options for a filter or a codec.
static AVDictionary *makeOptions(NSDictionary<NSString *, NSString *> *values) {
  AVDictionary *options = NULL;
  for (NSString *key in values) {
    av_dict_set(&options, key.UTF8String, values[key].UTF8String, 0);
  }
  return options;
}

/// Creates a filter with the given options, connects the output of `last` to its input and makes it the last filter.
static int appendFilter(AVFilterGraph *graph, AVFilterContext **last, const char *name, AVDictionary *options) {
  const AVFilter *filter = avfilter_get_by_name(name);
  if (!filter) {
    LOG_ERROR(@"The %s filter is missing", name);
    av_dict_free(&options);
    return AVERROR_FILTER_NOT_FOUND;
  }
  AVFilterContext *context = avfilter_graph_alloc_filter(graph, filter, NULL);
  if (!context) {
    av_dict_free(&options);
    return AVERROR(ENOMEM);
  }
  int ret = avfilter_init_dict(context, &options);
  if (ret >= 0 && av_dict_count(options) > 0) {
    LOG_WARN(@"The %s filter ignored %d options", name, av_dict_count(options));
  }
  av_dict_free(&options);
  if (ret < 0) {
    LOG_ERROR(@"Cannot set up the %s filter: %s (%d)", name, av_err2str(ret), ret);
    return ret;
  }
  if (*last) {
    ret = avfilter_link(*last, 0, context, 0);
    if (ret < 0) { return ret; }
  }
  *last = context;
  return 0;
}

/// Creates the buffer source of a filter graph, which receives the decoded frames.
static int createSource(ShareStream *stream, const char *name, AVBufferSrcParameters *parameters) {
  stream->source = avfilter_graph_alloc_filter(stream->graph, avfilter_get_by_name(name), "in");
  if (!stream->source) { return AVERROR(ENOMEM); }
  int ret = av_buffersrc_parameters_set(stream->source, parameters);
  if (ret < 0) { return ret; }
  return avfilter_init_dict(stream->source, NULL);
}

/// Creates the buffer sink of a filter graph, which hands the filtered frames to the encoder, and configures the graph.
static int finishGraph(ShareStream *stream, const char *name, AVFilterContext *last) {
  stream->sink = NULL;
  int ret = appendFilter(stream->graph, &last, name, NULL);
  if (ret < 0) { return ret; }
  stream->sink = last;
  ret = avfilter_graph_config(stream->graph, NULL);
  if (ret < 0) {
    LOG_ERROR(@"Cannot configure the filters: %s (%d)", av_err2str(ret), ret);
  }
  return ret;
}

/// Adds a trim filter keeping only the frames of the clip, if a part of the original has to be left out.
static int appendTrim(ShareJob *job, ShareStream *stream, AVFilterContext **last, const char *name) {
  if (job->trimStart < 0 && job->trimEnd < 0) { return 0; }
  NSMutableDictionary *options = [NSMutableDictionary dictionary];
  if (job->trimStart >= 0) { options[@"start"] = [NSString stringWithFormat:@"%.6f", job->trimStart]; }
  if (job->trimEnd >= 0) { options[@"end"] = [NSString stringWithFormat:@"%.6f", job->trimEnd]; }
  return appendFilter(stream->graph, last, name, makeOptions(options));
}

/// Returns the size of the video of the clip: the size the original is shown at, scaled down to the largest size for sharing.
static void shareVideoSize(const AVFrame *frame, int *width, int *height) {
  AVRational aspect = frame->sample_aspect_ratio;
  if (aspect.num <= 0 || aspect.den <= 0) { aspect = (AVRational){1, 1}; }
  const double displayWidth = frame->width * av_q2d(aspect);
  const double displayHeight = frame->height;
  const double longSide = MAX(displayWidth, displayHeight);
  const double shortSide = MIN(displayWidth, displayHeight);
  const double scale = MIN(1, MIN(ShareMaxLongSide / longSide, ShareMaxShortSide / shortSide));
  // H.264 with 4:2:0 chroma needs even sizes.
  *width = MAX(2, (int)lround(displayWidth * scale / 2) * 2);
  *height = MAX(2, (int)lround(displayHeight * scale / 2) * 2);
}

/// Sets up the filters of the video: trimming, scaling, drawing the subtitles and making the clip start at zero.
static int buildVideoGraph(ShareJob *job, const AVFrame *frame, BOOL withSubtitles) {
  ShareStream *stream = &job->video;
  avfilter_graph_free(&stream->graph);
  stream->source = NULL;
  stream->sink = NULL;
  stream->graph = avfilter_graph_alloc();
  if (!stream->graph) { return AVERROR(ENOMEM); }

  AVBufferSrcParameters *parameters = av_buffersrc_parameters_alloc();
  if (!parameters) { return AVERROR(ENOMEM); }
  parameters->format = frame->format;
  parameters->width = frame->width;
  parameters->height = frame->height;
  parameters->sample_aspect_ratio = frame->sample_aspect_ratio;
  parameters->time_base = stream->inputStream->time_base;
  parameters->frame_rate = av_guess_frame_rate(job->input, stream->inputStream, NULL);
  parameters->color_space = frame->colorspace;
  parameters->color_range = frame->color_range;
  int ret = createSource(stream, "buffer", parameters);
  av_free(parameters);
  if (ret < 0) { return ret; }

  AVFilterContext *last = stream->source;
  ret = appendTrim(job, stream, &last, "trim");
  if (ret < 0) { return ret; }
  const double offset = withSubtitles ? job->subtitlesOffset : 0;
  if (offset != 0) {
    ret = appendFilter(stream->graph, &last, "setpts",
                       makeOptions(@{@"expr": [NSString stringWithFormat:@"PTS-%.6f/TB", offset]}));
    if (ret < 0) { return ret; }
  }
  // Scale before drawing the subtitles, so that they are drawn sharp at the size of the clip.
  int width, height;
  shareVideoSize(frame, &width, &height);
  ret = appendFilter(stream->graph, &last, "scale",
                     makeOptions(@{@"w": [NSString stringWithFormat:@"%d", width],
                                   @"h": [NSString stringWithFormat:@"%d", height]}));
  if (ret < 0) { return ret; }
  ret = appendFilter(stream->graph, &last, "setsar", makeOptions(@{@"sar": @"1"}));
  if (ret < 0) { return ret; }
  if (withSubtitles) {
    NSMutableDictionary *options = [NSMutableDictionary dictionaryWithObject:job->subtitlesPath forKey:@"filename"];
    if (job->subtitlesIndex >= 0) { options[@"si"] = [NSString stringWithFormat:@"%d", job->subtitlesIndex]; }
    if (job->subtitlesCharset) { options[@"charenc"] = job->subtitlesCharset; }
    ret = appendFilter(stream->graph, &last, "subtitles", makeOptions(options));
    if (ret < 0) { return ret; }
  }
  ret = appendFilter(stream->graph, &last, "setpts",
                     makeOptions(@{@"expr": [NSString stringWithFormat:@"PTS-%.6f/TB", job->cutTime - offset]}));
  if (ret < 0) { return ret; }
  ret = appendFilter(stream->graph, &last, "format", makeOptions(@{@"pix_fmts": @"yuv420p"}));
  if (ret < 0) { return ret; }
  return finishGraph(stream, "buffersink", last);
}

/// Sets up the filters of the audio: trimming, making the clip start at zero, and converting to stereo or mono at 44.1 or 48 kHz.
static int buildAudioGraph(ShareJob *job, const AVFrame *frame) {
  ShareStream *stream = &job->audio;
  stream->graph = avfilter_graph_alloc();
  if (!stream->graph) { return AVERROR(ENOMEM); }

  AVBufferSrcParameters *parameters = av_buffersrc_parameters_alloc();
  if (!parameters) { return AVERROR(ENOMEM); }
  parameters->format = frame->format;
  parameters->sample_rate = frame->sample_rate;
  parameters->time_base = stream->inputStream->time_base;
  int ret = av_channel_layout_copy(&parameters->ch_layout, &frame->ch_layout);
  if (ret >= 0) {
    ret = createSource(stream, "abuffer", parameters);
  }
  av_channel_layout_uninit(&parameters->ch_layout);
  av_free(parameters);
  if (ret < 0) { return ret; }

  AVFilterContext *last = stream->source;
  ret = appendTrim(job, stream, &last, "atrim");
  if (ret < 0) { return ret; }
  ret = appendFilter(stream->graph, &last, "asetpts",
                     makeOptions(@{@"expr": [NSString stringWithFormat:@"PTS-%.6f/TB", job->cutTime]}));
  if (ret < 0) { return ret; }
  const int sampleRate = frame->sample_rate == 44100 ? 44100 : 48000;
  ret = appendFilter(stream->graph, &last, "aformat",
                     makeOptions(@{@"sample_fmts": @"fltp",
                                   @"sample_rates": [NSString stringWithFormat:@"%d", sampleRate],
                                   @"channel_layouts": frame->ch_layout.nb_channels == 1 ? @"mono" : @"stereo"}));
  if (ret < 0) { return ret; }
  return finishGraph(stream, "abuffersink", last);
}

/// Creates the stream of the clip receiving the packets of the given encoder.
static int addOutputStream(ShareJob *job, ShareStream *stream) {
  stream->outputStream = avformat_new_stream(job->output, NULL);
  if (!stream->outputStream) { return AVERROR(ENOMEM); }
  int ret = avcodec_parameters_from_context(stream->outputStream->codecpar, stream->encoder);
  if (ret < 0) { return ret; }
  stream->outputStream->time_base = stream->encoder->time_base;
  av_dict_copy(&stream->outputStream->metadata, stream->inputStream->metadata, 0);
  return 0;
}

/// Opens the H.264 encoder of the video, using the hardware encoder of the Mac.
static int openVideoEncoder(ShareJob *job) {
  ShareStream *stream = &job->video;
  const AVCodec *codec = avcodec_find_encoder_by_name("h264_videotoolbox");
  if (!codec) {
    LOG_ERROR(@"The h264_videotoolbox encoder is missing");
    return AVERROR_ENCODER_NOT_FOUND;
  }
  stream->encoder = avcodec_alloc_context3(codec);
  if (!stream->encoder) { return AVERROR(ENOMEM); }
  AVCodecContext *encoder = stream->encoder;
  encoder->width = av_buffersink_get_w(stream->sink);
  encoder->height = av_buffersink_get_h(stream->sink);
  encoder->pix_fmt = av_buffersink_get_format(stream->sink);
  encoder->sample_aspect_ratio = (AVRational){1, 1};
  encoder->time_base = av_buffersink_get_time_base(stream->sink);
  AVRational frameRate = av_buffersink_get_frame_rate(stream->sink);
  if (frameRate.num <= 0 || frameRate.den <= 0) {
    frameRate = av_guess_frame_rate(job->input, stream->inputStream, NULL);
  }
  const double fps = frameRate.num > 0 && frameRate.den > 0 ? av_q2d(frameRate) : 25;
  if (frameRate.num > 0 && frameRate.den > 0) { encoder->framerate = frameRate; }
  // About 0.1 bit per pixel: 2.2 Mb/s for 720p and 5 Mb/s for 1080p at 24 frames per second.
  encoder->bit_rate = (int64_t)MIN(MAX(encoder->width * encoder->height * fps * 0.1, 1500000), 8000000);
  encoder->gop_size = MAX(1, (int)lround(fps * 2));
  // Keep the colors of the original, unless it is HDR: as it is converted to 8 bits without tone mapping, tagging it as HDR would
  // be wrong.
  const AVCodecParameters *original = stream->inputStream->codecpar;
  const BOOL isHDR = original->color_trc == AVCOL_TRC_SMPTE2084 || original->color_trc == AVCOL_TRC_ARIB_STD_B67;
  if (!isHDR) {
    encoder->color_primaries = original->color_primaries;
    encoder->color_trc = original->color_trc;
    encoder->colorspace = original->color_space;
  }
  encoder->color_range = AVCOL_RANGE_MPEG;
  if (job->output->oformat->flags & AVFMT_GLOBALHEADER) {
    encoder->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
  }
  AVDictionary *options = makeOptions(@{@"profile": @"high", @"allow_sw": @"1"});
  int ret = avcodec_open2(encoder, codec, &options);
  av_dict_free(&options);
  if (ret < 0) {
    LOG_ERROR(@"Cannot open the H.264 encoder: %s (%d)", av_err2str(ret), ret);
    return ret;
  }
  LOG_DEBUG(@"Encoding the video in H.264 at %dx%d, %lld b/s", encoder->width, encoder->height, encoder->bit_rate);
  ret = addOutputStream(job, stream);
  if (ret < 0) { return ret; }
  // Keep the rotation of videos filmed with a phone.
  const AVPacketSideData *displayMatrix = av_packet_side_data_get(original->coded_side_data, original->nb_coded_side_data,
                                                                  AV_PKT_DATA_DISPLAYMATRIX);
  if (displayMatrix) {
    AVCodecParameters *parameters = stream->outputStream->codecpar;
    AVPacketSideData *copy = av_packet_side_data_new(&parameters->coded_side_data, &parameters->nb_coded_side_data,
                                                     AV_PKT_DATA_DISPLAYMATRIX, displayMatrix->size, 0);
    if (copy) { memcpy(copy->data, displayMatrix->data, displayMatrix->size); }
  }
  return 0;
}

/// Opens the AAC encoder of the audio.
static int openAudioEncoder(ShareJob *job) {
  ShareStream *stream = &job->audio;
  const AVCodec *codec = avcodec_find_encoder(AV_CODEC_ID_AAC);
  if (!codec) {
    LOG_ERROR(@"The AAC encoder is missing");
    return AVERROR_ENCODER_NOT_FOUND;
  }
  stream->encoder = avcodec_alloc_context3(codec);
  if (!stream->encoder) { return AVERROR(ENOMEM); }
  AVCodecContext *encoder = stream->encoder;
  encoder->sample_fmt = av_buffersink_get_format(stream->sink);
  encoder->sample_rate = av_buffersink_get_sample_rate(stream->sink);
  int ret = av_buffersink_get_ch_layout(stream->sink, &encoder->ch_layout);
  if (ret < 0) { return ret; }
  encoder->bit_rate = encoder->ch_layout.nb_channels == 1 ? 96000 : 160000;
  encoder->time_base = (AVRational){1, encoder->sample_rate};
  if (job->output->oformat->flags & AVFMT_GLOBALHEADER) {
    encoder->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
  }
  ret = avcodec_open2(encoder, codec, NULL);
  if (ret < 0) {
    LOG_ERROR(@"Cannot open the AAC encoder: %s (%d)", av_err2str(ret), ret);
    return ret;
  }
  // The AAC encoder takes frames of a fixed number of samples.
  if (!(codec->capabilities & AV_CODEC_CAP_VARIABLE_FRAME_SIZE) && encoder->frame_size > 0) {
    av_buffersink_set_frame_size(stream->sink, encoder->frame_size);
  }
  stream->nextPts = AV_NOPTS_VALUE;
  return addOutputStream(job, stream);
}

/// Writes the header of the clip once every stream has its encoder, followed by the packets encoded until then.
/// - Parameter force: Write the header even if some streams have no encoder, as they had no frame to encode.
static int writeHeaderIfReady(ShareJob *job, BOOL force) {
  if (job->headerWritten) { return 0; }
  if (!force) {
    if (job->video.inputIndex >= 0 && !job->video.encoder) { return 0; }
    if (job->audio.inputIndex >= 0 && !job->audio.encoder) { return 0; }
  }
  if (job->output->nb_streams == 0) { return 0; }
  int ret = avio_open(&job->output->pb, job->outputURL.fileSystemRepresentation, AVIO_FLAG_WRITE);
  if (ret < 0) {
    LOG_ERROR(@"Cannot create %@: %s (%d)", job->outputURL.path, av_err2str(ret), ret);
    job->message = localized(@"clip.error.create", @"The clip file cannot be created");
    return ret;
  }
  // Put the index at the beginning of the file so the clip can be played while being downloaded.
  AVDictionary *options = makeOptions(@{@"movflags": @"+faststart"});
  ret = avformat_write_header(job->output, &options);
  av_dict_free(&options);
  if (ret < 0) {
    LOG_ERROR(@"Cannot write the header of %@: %s (%d)", job->outputURL.path, av_err2str(ret), ret);
    job->message = localized(@"clip.error.write", @"The clip cannot be written");
    return ret;
  }
  job->headerWritten = YES;
  for (int i = 0; i < job->pendingCount; i++) {
    if (ret >= 0) {
      ret = av_interleaved_write_frame(job->output, job->pendingPackets[i]);
    }
    av_packet_free(&job->pendingPackets[i]);
  }
  job->pendingCount = 0;
  if (ret < 0) {
    job->message = localized(@"clip.error.write", @"The clip cannot be written");
  }
  return ret;
}

/// Writes a packet to the clip, or keeps it until the header can be written.
static int writePacket(ShareJob *job, AVPacket *packet) {
  if (!job->headerWritten) {
    AVPacket **packets = av_realloc_array(job->pendingPackets, job->pendingCount + 1, sizeof(*packets));
    if (!packets) { return AVERROR(ENOMEM); }
    job->pendingPackets = packets;
    AVPacket *copy = av_packet_alloc();
    if (!copy) { return AVERROR(ENOMEM); }
    av_packet_move_ref(copy, packet);
    job->pendingPackets[job->pendingCount++] = copy;
    return 0;
  }
  int ret = av_interleaved_write_frame(job->output, packet);
  if (ret < 0) {
    LOG_ERROR(@"Cannot write a packet to %@: %s (%d)", job->outputURL.path, av_err2str(ret), ret);
    job->message = localized(@"clip.error.write", @"The clip cannot be written");
  }
  return ret;
}

/// Sends a frame to an encoder, `NULL` to flush it, and writes the packets it gives back.
static int encodeFrame(ShareJob *job, ShareStream *stream, AVFrame *frame) {
  int ret = avcodec_send_frame(stream->encoder, frame);
  if (ret < 0 && ret != AVERROR_EOF) {
    LOG_ERROR(@"Cannot encode a frame: %s (%d)", av_err2str(ret), ret);
    job->message = localized(@"clip.error.encode", @"The clip cannot be encoded");
    return ret;
  }
  while (YES) {
    ret = avcodec_receive_packet(stream->encoder, job->encodedPacket);
    if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) { return 0; }
    if (ret < 0) {
      LOG_ERROR(@"Cannot encode a frame: %s (%d)", av_err2str(ret), ret);
      job->message = localized(@"clip.error.encode", @"The clip cannot be encoded");
      return ret;
    }
    job->encodedPacket->stream_index = stream->outputStream->index;
    av_packet_rescale_ts(job->encodedPacket, stream->encoder->time_base, stream->outputStream->time_base);
    ret = writePacket(job, job->encodedPacket);
    av_packet_unref(job->encodedPacket);
    if (ret < 0) { return ret; }
  }
}

/// Encodes the frames the filters of a stream let through.
static int drainFilters(ShareJob *job, ShareStream *stream) {
  while (YES) {
    int ret = av_buffersink_get_frame(stream->sink, job->filteredFrame);
    if (ret == AVERROR(EAGAIN)) { return 0; }
    if (ret == AVERROR_EOF) {
      stream->filterEnded = YES;
      return 0;
    }
    if (ret < 0) {
      LOG_ERROR(@"Cannot filter a frame: %s (%d)", av_err2str(ret), ret);
      job->message = localized(@"clip.error.encode", @"The clip cannot be encoded");
      return ret;
    }
    AVFrame *frame = job->filteredFrame;
    const AVRational timeBase = av_buffersink_get_time_base(stream->sink);
    if (stream == &job->audio) {
      // Number the audio samples one after the other, as the encoder expects.
      if (stream->nextPts == AV_NOPTS_VALUE) {
        stream->nextPts = frame->pts != AV_NOPTS_VALUE ?
            av_rescale_q(frame->pts, timeBase, stream->encoder->time_base) : 0;
      }
      frame->pts = stream->nextPts;
      stream->nextPts += frame->nb_samples;
    } else {
      frame->pict_type = AV_PICTURE_TYPE_NONE;
    }
    // Report the progress from the video, or from the audio when there is no video.
    const BOOL reportsProgress = stream == &job->video || job->video.inputIndex < 0;
    if (reportsProgress && job->progress && job->duration > 0 && frame->pts != AV_NOPTS_VALUE) {
      const AVRational frameTimeBase = stream == &job->audio ? stream->encoder->time_base : timeBase;
      const double fraction = MIN(MAX(frame->pts * av_q2d(frameTimeBase) / job->duration, 0), 1);
      if (fraction - job->reportedProgress >= 0.01) {
        job->reportedProgress = fraction;
        job->progress(fraction);
      }
    }
    job->wroteFrames = YES;
    ret = encodeFrame(job, stream, frame);
    av_frame_unref(frame);
    if (ret < 0) { return ret; }
  }
}

/// Sets up the filters and the encoder of a stream from its first decoded frame.
static int setUpStream(ShareJob *job, ShareStream *stream, const AVFrame *frame) {
  int ret;
  if (stream == &job->video) {
    ret = job->subtitlesPath ? buildVideoGraph(job, frame, YES) : AVERROR(EINVAL);
    if (ret >= 0) {
      job->burnedSubtitles = YES;
    } else {
      if (job->subtitlesPath) {
        LOG_WARN(@"Cannot draw the subtitles of %@ on the clip, saving it without subtitles", job->subtitlesPath);
      }
      ret = buildVideoGraph(job, frame, NO);
    }
    if (ret >= 0) { ret = openVideoEncoder(job); }
  } else {
    ret = buildAudioGraph(job, frame);
    if (ret >= 0) { ret = openAudioEncoder(job); }
  }
  if (ret < 0) {
    if (!job->message) { job->message = localized(@"clip.error.encode", @"The clip cannot be encoded"); }
    return ret;
  }
  return writeHeaderIfReady(job, NO);
}

/// Sends a packet to the decoder of a stream, `NULL` to flush it, and passes the decoded frames through the filters and the encoder.
static int decodePacket(ShareJob *job, ShareStream *stream, const AVPacket *packet) {
  int ret = avcodec_send_packet(stream->decoder, packet);
  if (ret < 0 && ret != AVERROR_EOF) {
    // A damaged packet does not prevent saving the rest.
    LOG_WARN(@"Cannot decode a packet of stream %d: %s (%d)", stream->inputIndex, av_err2str(ret), ret);
    return 0;
  }
  while (!stream->filterEnded) {
    ret = avcodec_receive_frame(stream->decoder, job->frame);
    if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) { return 0; }
    if (ret < 0) {
      LOG_WARN(@"Cannot decode a frame of stream %d: %s (%d)", stream->inputIndex, av_err2str(ret), ret);
      return 0;
    }
    job->frame->pts = job->frame->best_effort_timestamp;
    if (!stream->graph) {
      ret = setUpStream(job, stream, job->frame);
      if (ret < 0) {
        av_frame_unref(job->frame);
        return ret;
      }
    }
    ret = av_buffersrc_add_frame(stream->source, job->frame);
    av_frame_unref(job->frame);
    if (ret == AVERROR_EOF) {
      stream->filterEnded = YES;
      return 0;
    }
    if (ret < 0) {
      LOG_ERROR(@"Cannot filter a frame: %s (%d)", av_err2str(ret), ret);
      job->message = localized(@"clip.error.encode", @"The clip cannot be encoded");
      return ret;
    }
    ret = drainFilters(job, stream);
    if (ret < 0) { return ret; }
  }
  return 0;
}

/// Flushes the decoder, the filters and the encoder of a stream.
static int flushStream(ShareJob *job, ShareStream *stream) {
  if (stream->inputIndex < 0 || !stream->decoder) { return 0; }
  int ret = decodePacket(job, stream, NULL);
  if (ret < 0) { return ret; }
  if (!stream->graph) { return 0; }
  if (!stream->filterEnded) {
    ret = av_buffersrc_add_frame(stream->source, NULL);
    if (ret < 0 && ret != AVERROR_EOF) { return ret; }
    ret = drainFilters(job, stream);
    if (ret < 0) { return ret; }
  }
  return 0;
}

/// Opens the decoder of a stream of the original.
static int openDecoder(ShareStream *stream) {
  const AVCodec *codec = avcodec_find_decoder(stream->inputStream->codecpar->codec_id);
  if (!codec) { return AVERROR_DECODER_NOT_FOUND; }
  stream->decoder = avcodec_alloc_context3(codec);
  if (!stream->decoder) { return AVERROR(ENOMEM); }
  int ret = avcodec_parameters_to_context(stream->decoder, stream->inputStream->codecpar);
  if (ret < 0) { return ret; }
  stream->decoder->pkt_timebase = stream->inputStream->time_base;
  stream->decoder->thread_count = 0;
  return avcodec_open2(stream->decoder, codec, NULL);
}

/// Chooses a stream of the given type: the wanted one if it is usable, otherwise the one FFmpeg finds best.
static int chooseStream(AVFormatContext *context, enum AVMediaType type, NSInteger wanted) {
  if (wanted >= 0 && wanted < context->nb_streams) {
    AVStream *stream = context->streams[wanted];
    if (stream->codecpar->codec_type == type && !(stream->disposition & AV_DISPOSITION_ATTACHED_PIC)) {
      return (int)wanted;
    }
  }
  const int index = av_find_best_stream(context, type, -1, -1, NULL, 0);
  if (index < 0) { return -1; }
  if (context->streams[index]->disposition & AV_DISPOSITION_ATTACHED_PIC) { return -1; }
  return index;
}

/// Copies the subtitles of the original shown during the clip, and the fonts they use, into a Matroska file of their own.
///
/// The subtitles filter reads the whole file it is given, which takes long for a film, all the more when it is stored in the cloud.
/// - Returns: The number of subtitles copied, or a negative FFmpeg error code.
static int extractSubtitles(NSURL *inputURL, int streamIndex, int64_t from, int64_t to, NSURL *outputURL) {
  AVFormatContext *input = NULL;
  AVFormatContext *output = NULL;
  AVPacket *packet = NULL;
  int count = 0;
  int outputIndex = -1;
  int ret = avformat_open_input(&input, inputURL.fileSystemRepresentation, NULL, NULL);
  if (ret >= 0) { ret = avformat_find_stream_info(input, NULL); }
  if (ret >= 0) { ret = avformat_alloc_output_context2(&output, NULL, "matroska", outputURL.fileSystemRepresentation); }
  if (ret >= 0 && !(packet = av_packet_alloc())) { ret = AVERROR(ENOMEM); }
  if (ret >= 0 && (streamIndex < 0 || streamIndex >= input->nb_streams)) { ret = AVERROR_STREAM_NOT_FOUND; }
  for (unsigned int i = 0; ret >= 0 && i < input->nb_streams; i++) {
    AVStream *stream = input->streams[i];
    const BOOL isFont = stream->codecpar->codec_type == AVMEDIA_TYPE_ATTACHMENT;
    stream->discard = (int)i == streamIndex ? AVDISCARD_DEFAULT : AVDISCARD_ALL;
    if ((int)i != streamIndex && !isFont) { continue; }
    AVStream *copy = avformat_new_stream(output, NULL);
    if (!copy) {
      ret = AVERROR(ENOMEM);
      break;
    }
    ret = avcodec_parameters_copy(copy->codecpar, stream->codecpar);
    copy->codecpar->codec_tag = 0;
    copy->time_base = stream->time_base;
    av_dict_copy(&copy->metadata, stream->metadata, 0);
    if ((int)i == streamIndex) { outputIndex = copy->index; }
  }
  if (ret >= 0) { ret = avio_open(&output->pb, outputURL.fileSystemRepresentation, AVIO_FLAG_WRITE); }
  if (ret >= 0) { ret = avformat_write_header(output, NULL); }
  const int64_t fileStart = ret >= 0 && input->start_time != AV_NOPTS_VALUE ? input->start_time : 0;
  if (ret >= 0 && from > fileStart) {
    const int64_t target = MAX(from - ShareSubtitlesLookBehind, fileStart);
    ret = seekToTime(input, target, fileStart);
  }
  while (ret >= 0) {
    ret = av_read_frame(input, packet);
    if (ret == AVERROR_EOF) {
      ret = 0;
      break;
    }
    if (ret < 0) { break; }
    if (packet->stream_index != streamIndex || packet->pts == AV_NOPTS_VALUE) {
      av_packet_unref(packet);
      continue;
    }
    AVStream *stream = input->streams[streamIndex];
    const int64_t time = av_rescale_q(packet->pts, stream->time_base, AV_TIME_BASE_Q);
    if (to != AV_NOPTS_VALUE && time > to) {
      av_packet_unref(packet);
      break;
    }
    // Keep the timestamps of the original, as the subtitles are drawn on frames still carrying them.
    packet->stream_index = outputIndex;
    packet->pos = -1;
    av_packet_rescale_ts(packet, stream->time_base, output->streams[outputIndex]->time_base);
    ret = av_interleaved_write_frame(output, packet);
    count++;
  }
  if (ret >= 0) { ret = av_write_trailer(output); }
  if (ret < 0) {
    LOG_ERROR(@"Cannot copy the subtitles of %@: %s (%d)", inputURL.path, av_err2str(ret), ret);
  }
  av_packet_free(&packet);
  avformat_close_input(&input);
  if (output) {
    avio_closep(&output->pb);
    avformat_free_context(output);
  }
  return ret < 0 ? ret : count;
}

/// Returns `YES` if the given subtitle stream holds text, which the subtitles filter can draw, rather than pictures.
static BOOL isTextSubtitleStream(AVStream *stream) {
  if (stream->codecpar->codec_type != AVMEDIA_TYPE_SUBTITLE) { return NO; }
  const AVCodecDescriptor *descriptor = avcodec_descriptor_get(stream->codecpar->codec_id);
  return descriptor && (descriptor->props & AV_CODEC_PROP_TEXT_SUB);
}

/// Frees everything a clip saved for sharing used.
static void freeShareStream(ShareStream *stream) {
  avcodec_free_context(&stream->decoder);
  avcodec_free_context(&stream->encoder);
  avfilter_graph_free(&stream->graph);
}

/// Saves the given part of a file as an MP4 file playable everywhere: H.264 video and AAC audio, with the subtitles drawn on the
/// video.
static int shareClip(NSURL *inputURL, NSURL *outputURL, double start, double end, NSInteger videoIndex, NSInteger audioIndex,
                     NSURL *subtitlesURL, NSInteger subtitlesIndex, void (^progress)(double), BOOL *burnedSubtitles,
                     NSString **message)
{
  ShareJob job = {0};
  job.outputURL = outputURL;
  job.progress = progress;
  job.video.inputIndex = -1;
  job.audio.inputIndex = -1;
  job.subtitlesIndex = -1;
  AVPacket *packet = NULL;
  NSURL *temporarySubtitlesURL = nil;
  int ret;

  @try {
    ret = avformat_open_input(&job.input, inputURL.fileSystemRepresentation, NULL, NULL);
    if (ret >= 0) {
      ret = avformat_find_stream_info(job.input, NULL);
    }
    if (ret < 0) {
      LOG_ERROR(@"Cannot open %@ to export a clip: %s (%d)", inputURL.path, av_err2str(ret), ret);
      job.message = localized(@"clip.error.open", @"The file cannot be read");
      return ret;
    }
    ret = avformat_alloc_output_context2(&job.output, NULL, "mp4", outputURL.fileSystemRepresentation);
    job.frame = av_frame_alloc();
    job.filteredFrame = av_frame_alloc();
    job.encodedPacket = av_packet_alloc();
    packet = av_packet_alloc();
    if (ret < 0 || !job.output || !job.frame || !job.filteredFrame || !job.encodedPacket || !packet) {
      job.message = localized(@"clip.error.write", @"The clip cannot be written");
      return ret < 0 ? ret : AVERROR(ENOMEM);
    }

    ShareStream *streams[] = {&job.video, &job.audio};
    job.video.inputIndex = chooseStream(job.input, AVMEDIA_TYPE_VIDEO, videoIndex);
    job.audio.inputIndex = chooseStream(job.input, AVMEDIA_TYPE_AUDIO, audioIndex);
    for (int i = 0; i < 2; i++) {
      ShareStream *stream = streams[i];
      if (stream->inputIndex < 0) { continue; }
      stream->inputStream = job.input->streams[stream->inputIndex];
      ret = openDecoder(stream);
      if (ret < 0) {
        LOG_WARN(@"Cannot decode stream %d of %@, leaving it out: %s (%d)", stream->inputIndex, inputURL.path, av_err2str(ret),
                 ret);
        avcodec_free_context(&stream->decoder);
        stream->inputIndex = -1;
      }
    }
    if (job.video.inputIndex < 0 && job.audio.inputIndex < 0) {
      LOG_ERROR(@"No video or audio stream to encode in %@", inputURL.path);
      job.message = localized(@"clip.error.no_stream", @"The file has no video or audio stream that can be copied");
      return AVERROR_STREAM_NOT_FOUND;
    }
    for (unsigned int i = 0; i < job.input->nb_streams; i++) {
      if ((int)i != job.video.inputIndex && (int)i != job.audio.inputIndex) {
        job.input->streams[i]->discard = AVDISCARD_ALL;
      }
    }

    // mpv reports times from the start of the file, while frames carry the timestamps of the container.
    const int64_t fileStart = job.input->start_time != AV_NOPTS_VALUE ? job.input->start_time : 0;
    const int64_t startTime = fileStart + llround(MAX(start, 0) * AV_TIME_BASE);
    const int64_t endTime = end >= 0 ? fileStart + llround(end * AV_TIME_BASE) : AV_NOPTS_VALUE;
    job.cutTime = (double)(start > 0 ? startTime : fileStart) / AV_TIME_BASE;
    job.trimStart = start > 0 ? (double)startTime / AV_TIME_BASE : -1;
    job.trimEnd = endTime != AV_NOPTS_VALUE ? (double)endTime / AV_TIME_BASE : -1;
    job.duration = (end >= 0 ? end : (job.input->duration > 0 ? (double)job.input->duration / AV_TIME_BASE : 0)) - MAX(start, 0);

    // Subtitles stored in the original are copied to a small file of their own first. Subtitle files are used as they are.
    if (subtitlesURL && [subtitlesURL isEqual:inputURL]) {
      if (subtitlesIndex >= 0 && subtitlesIndex < job.input->nb_streams
          && isTextSubtitleStream(job.input->streams[subtitlesIndex])) {
        NSString *name = [NSString stringWithFormat:@"iina-clip-subtitles-%@.mkv", NSUUID.UUID.UUIDString];
        temporarySubtitlesURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];
        const int count = extractSubtitles(inputURL, (int)subtitlesIndex, startTime, endTime, temporarySubtitlesURL);
        if (count > 0) {
          job.subtitlesPath = temporarySubtitlesURL.path;
        } else if (count == 0) {
          LOG_DEBUG(@"No subtitle of stream %ld during the clip", (long)subtitlesIndex);
        }
      } else {
        LOG_WARN(@"Stream %ld of %@ holds no text subtitles, saving the clip without subtitles", (long)subtitlesIndex,
                 inputURL.path);
      }
    } else if (subtitlesURL) {
      job.subtitlesPath = subtitlesURL.path;
      job.subtitlesOffset = (double)fileStart / AV_TIME_BASE;
      // FFmpeg expects UTF-8 subtitles, older subtitle files are often in Windows Latin 1.
      NSData *data = [NSData dataWithContentsOfURL:subtitlesURL options:NSDataReadingMappedIfSafe error:nil];
      if (data && ![[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]) {
        job.subtitlesCharset = @"CP1252";
      }
    }
    if (job.subtitlesPath) {
      LOG_DEBUG(@"Drawing the subtitles of %@ on the clip", job.subtitlesPath);
    }

    if (start > 0) {
      int64_t seekTime = MAX(startTime - AV_TIME_BASE, fileStart);
      if (job.video.inputIndex >= 0) {
        findKeyframeBefore(job.input, job.video.inputIndex, startTime, fileStart, packet, &seekTime);
      }
      ret = seekToTime(job.input, seekTime, fileStart);
      if (ret < 0) {
        LOG_ERROR(@"Cannot seek to %f in %@: %s (%d)", start, inputURL.path, av_err2str(ret), ret);
        job.message = localized(@"clip.error.open", @"The file cannot be read");
        return ret;
      }
    }

    while (YES) {
      const BOOL videoDone = job.video.inputIndex < 0 || job.video.inputEnded || job.video.filterEnded;
      const BOOL audioDone = job.audio.inputIndex < 0 || job.audio.inputEnded || job.audio.filterEnded;
      if (videoDone && audioDone) { break; }
      ret = av_read_frame(job.input, packet);
      if (ret == AVERROR_EOF) { break; }
      if (ret < 0) {
        LOG_ERROR(@"Cannot read %@: %s (%d)", inputURL.path, av_err2str(ret), ret);
        job.message = localized(@"clip.error.open", @"The file cannot be read");
        return ret;
      }
      ShareStream *stream = packet->stream_index == job.video.inputIndex ? &job.video :
          packet->stream_index == job.audio.inputIndex ? &job.audio : NULL;
      if (!stream || stream->inputEnded || stream->filterEnded) {
        av_packet_unref(packet);
        continue;
      }
      const int64_t timestamp = packet->dts != AV_NOPTS_VALUE ? packet->dts : packet->pts;
      if (endTime != AV_NOPTS_VALUE && timestamp != AV_NOPTS_VALUE
          && av_rescale_q(timestamp, stream->inputStream->time_base, AV_TIME_BASE_Q) > endTime + ShareReadMargin) {
        stream->inputEnded = YES;
        av_packet_unref(packet);
        continue;
      }
      ret = decodePacket(&job, stream, packet);
      av_packet_unref(packet);
      if (ret < 0) { return ret; }
    }

    for (int i = 0; i < 2; i++) {
      ret = flushStream(&job, streams[i]);
      if (ret < 0) { return ret; }
    }
    if (!job.wroteFrames) {
      LOG_ERROR(@"Nothing to encode between %f and %f in %@", start, end, inputURL.path);
      job.message = localized(@"clip.error.empty", @"The selection contains nothing to copy");
      return AVERROR_INVALIDDATA;
    }
    ret = writeHeaderIfReady(&job, YES);
    if (ret < 0) { return ret; }
    for (int i = 0; i < 2; i++) {
      if (!streams[i]->encoder) { continue; }
      ret = encodeFrame(&job, streams[i], NULL);
      if (ret < 0) { return ret; }
    }
    ret = av_write_trailer(job.output);
    if (ret < 0) {
      LOG_ERROR(@"Cannot finish writing %@: %s (%d)", outputURL.path, av_err2str(ret), ret);
      job.message = localized(@"clip.error.write", @"The clip cannot be written");
      return ret;
    }
    *burnedSubtitles = job.burnedSubtitles;
    return 0;
  }
  @finally {
    *message = job.message;
    av_packet_free(&packet);
    for (int i = 0; i < job.pendingCount; i++) {
      av_packet_free(&job.pendingPackets[i]);
    }
    av_freep(&job.pendingPackets);
    freeShareStream(&job.video);
    freeShareStream(&job.audio);
    av_frame_free(&job.frame);
    av_frame_free(&job.filteredFrame);
    av_packet_free(&job.encodedPacket);
    avformat_close_input(&job.input);
    if (job.output) {
      avio_closep(&job.output->pb);
      avformat_free_context(job.output);
    }
    if (temporarySubtitlesURL) {
      [NSFileManager.defaultManager removeItemAtURL:temporarySubtitlesURL error:nil];
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

/// Writes a clip to a temporary file next to the destination, then gives it its final name once complete.
/// - Parameter write: Writes the clip to the given temporary file, returning zero on success or a negative FFmpeg error code.
+ (int)writeToURL:(NSURL *)destination message:(NSString **)message using:(int (^)(NSURL *partialURL))write
{
  NSURL *partialURL = [destination URLByAppendingPathExtension:@"part"];
  int ret = write(partialURL);
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

/// Remuxes the clip to a temporary file next to the destination, then gives it its final name once complete.
+ (int)writeClipFromURL:(NSURL *)inputURL
                  toURL:(NSURL *)destination
                 format:(const AVOutputFormat *)format
                  start:(double)start
                    end:(double)end
               progress:(void (^)(double))progress
            muxerFailed:(BOOL *)muxerFailed
                message:(NSString **)message
{
  __block NSString *remuxMessage = nil;
  int ret = [self writeToURL:destination message:message using:^int(NSURL *partialURL) {
    LOG_DEBUG(@"Writing clip %f-%f of %@ to %@ using the %s muxer", start, end, inputURL.path, partialURL.path, format->name);
    NSString *failure = nil;
    int result = remuxClip(inputURL, partialURL, format, start, end, progress, muxerFailed, &failure);
    remuxMessage = failure;
    return result;
  }];
  if (ret < 0 && remuxMessage) { *message = remuxMessage; }
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

+ (NSURL *)exportShareableClipFromURL:(NSURL *)inputURL
                                  toURL:(NSURL *)outputURL
                                  start:(double)start
                                    end:(double)end
                            videoStream:(NSInteger)videoStream
                            audioStream:(NSInteger)audioStream
                           subtitlesURL:(NSURL *)subtitlesURL
                        subtitlesStream:(NSInteger)subtitlesStream
                               progress:(void (^)(double))progress
                        burnedSubtitles:(BOOL *)burnedSubtitles
                                  error:(NSError **)error
{
  __block NSString *message = nil;
  __block BOOL burned = NO;
  NSString *renameMessage = nil;
  int ret = [self writeToURL:outputURL message:&renameMessage using:^int(NSURL *partialURL) {
    LOG_DEBUG(@"Encoding clip %f-%f of %@ to %@ for sharing", start, end, inputURL.path, partialURL.path);
    NSString *failure = nil;
    BOOL drewSubtitles = NO;
    int result = shareClip(inputURL, partialURL, start, end, videoStream, audioStream, subtitlesURL, subtitlesStream, progress,
                           &drewSubtitles, &failure);
    message = failure;
    burned = drewSubtitles;
    return result;
  }];
  if (ret < 0) {
    if (error) {
      *error = [NSError errorWithDomain:ClipExporterErrorDomain code:ret
                               userInfo:@{NSLocalizedDescriptionKey: renameMessage ?: message ?: @""}];
    }
    return nil;
  }
  if (burnedSubtitles) { *burnedSubtitles = burned; }
  LOG_DEBUG(@"Clip for sharing written to %@", outputURL.path);
  return outputURL;
}

@end
