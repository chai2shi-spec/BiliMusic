/*
 * BiliMusic 本机歌词转写：音频文件解码为 16kHz/单声道/16bit 小端 PCM。
 * 输入：m4a(aac) / mp3 / flac 等系统可解复用的音频文件。
 * 输出：原始 PCM 文件，供 speechRecognizer 离线识别使用。
 */
#include "napi/native_api.h"
#include "multimedia/player_framework/native_avsource.h"
#include "multimedia/player_framework/native_avdemuxer.h"
#include "multimedia/player_framework/native_avcodec_audiocodec.h"
#include "multimedia/player_framework/native_avcodec_base.h"
#include "multimedia/player_framework/native_avbuffer.h"
#include "multimedia/player_framework/native_avformat.h"
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

namespace {

constexpr int32_t OUT_SAMPLE_RATE = 16000;
constexpr int32_t OUT_CHANNELS = 1;
constexpr size_t DEMUX_SCRATCH_CAPACITY = 4 * 1024 * 1024;
constexpr int STALL_TIMEOUT_MS = 60000;

enum DecodeErrorCode {
    DECODE_ERR_OPEN_FILE = 1,
    DECODE_ERR_PARSE_FILE = 2,
    DECODE_ERR_NO_AUDIO_TRACK = 3,
    DECODE_ERR_BAD_FORMAT = 4,
    DECODE_ERR_CODEC_CREATE = 5,
    DECODE_ERR_CODEC_SETUP = 6,
    DECODE_ERR_DECODE = 7,
    DECODE_ERR_TIMEOUT = 8,
    DECODE_ERR_OUTPUT_FILE = 9,
    DECODE_ERR_NO_MEMORY = 10,
};

static inline float SampleToFloat(const uint8_t *p, int32_t fmt)
{
    switch (fmt) {
        case SAMPLE_U8:
        case SAMPLE_U8P:
            return (static_cast<float>(p[0]) - 128.0f) / 128.0f;
        case SAMPLE_S16LE:
        case SAMPLE_S16P: {
            int16_t v = 0;
            memcpy(&v, p, sizeof(v));
            return static_cast<float>(v) / 32768.0f;
        }
        case SAMPLE_S24LE:
        case SAMPLE_S24P: {
            int32_t raw = static_cast<int32_t>(p[0]) | (static_cast<int32_t>(p[1]) << 8) |
                (static_cast<int32_t>(p[2]) << 16);
            if ((raw & 0x800000) != 0) {
                raw |= static_cast<int32_t>(0xFF000000);
            }
            return static_cast<float>(raw) / 8388608.0f;
        }
        case SAMPLE_S32LE:
        case SAMPLE_S32P: {
            int32_t v = 0;
            memcpy(&v, p, sizeof(v));
            return static_cast<float>(v) / 2147483648.0f;
        }
        case SAMPLE_F32LE:
        case SAMPLE_F32P: {
            float v = 0.0f;
            memcpy(&v, p, sizeof(v));
            return v;
        }
        default:
            return 0.0f;
    }
}

static inline int32_t BytesPerSample(int32_t fmt)
{
    switch (fmt) {
        case SAMPLE_U8:
        case SAMPLE_U8P:
            return 1;
        case SAMPLE_S16LE:
        case SAMPLE_S16P:
            return 2;
        case SAMPLE_S24LE:
        case SAMPLE_S24P:
            return 3;
        case SAMPLE_S32LE:
        case SAMPLE_S32P:
        case SAMPLE_F32LE:
        case SAMPLE_F32P:
            return 4;
        default:
            return 2;
    }
}

static inline bool IsPlanarFormat(int32_t fmt)
{
    return fmt == SAMPLE_U8P || fmt == SAMPLE_S16P || fmt == SAMPLE_S24P || fmt == SAMPLE_S32P ||
        fmt == SAMPLE_F32P;
}

static inline int16_t FloatToInt16(float v)
{
    if (v >= 1.0f) {
        return 32767;
    }
    if (v <= -1.0f) {
        return -32768;
    }
    return static_cast<int16_t>(v * 32767.0f);
}

// 混单声道 + 线性插值重采样到 16kHz + 输出 s16le（流式，跨 chunk 维护插值位置）
class PcmResampler {
public:
    bool configured = false;

    void Configure(int32_t inRate, int32_t channels, int32_t fmt)
    {
        inRate_ = (inRate > 0) ? inRate : OUT_SAMPLE_RATE;
        channels_ = (channels > 0) ? channels : OUT_CHANNELS;
        fmt_ = fmt;
        step_ = static_cast<double>(inRate_) / static_cast<double>(OUT_SAMPLE_RATE);
        configured = true;
    }

    void Process(const uint8_t *data, size_t size, std::vector<int16_t> &out)
    {
        if (!configured || data == nullptr || size == 0) {
            return;
        }
        ToMono(data, size);
        while (pos_ + 1.0 < static_cast<double>(pending_.size())) {
            size_t idx = static_cast<size_t>(pos_);
            double frac = pos_ - static_cast<double>(idx);
            float v = pending_[idx] + (pending_[idx + 1] - pending_[idx]) * static_cast<float>(frac);
            out.push_back(FloatToInt16(v));
            pos_ += step_;
        }
        size_t consumed = static_cast<size_t>(pos_);
        if (consumed > 0 && consumed <= pending_.size()) {
            pending_.erase(pending_.begin(), pending_.begin() + static_cast<long>(consumed));
            pos_ -= static_cast<double>(consumed);
        }
    }

private:
    void ToMono(const uint8_t *data, size_t size)
    {
        const int32_t bps = BytesPerSample(fmt_);
        const size_t frameBytes = static_cast<size_t>(bps) * static_cast<size_t>(channels_);
        if (frameBytes == 0) {
            return;
        }
        if (IsPlanarFormat(fmt_)) {
            const size_t frames = size / frameBytes;
            for (size_t f = 0; f < frames; ++f) {
                float sum = 0.0f;
                for (int32_t c = 0; c < channels_; ++c) {
                    const uint8_t *p = data + static_cast<size_t>(c) * frames * static_cast<size_t>(bps) +
                        f * static_cast<size_t>(bps);
                    sum += SampleToFloat(p, fmt_);
                }
                pending_.push_back(sum / static_cast<float>(channels_));
            }
        } else {
            const size_t frames = size / frameBytes;
            for (size_t f = 0; f < frames; ++f) {
                float sum = 0.0f;
                for (int32_t c = 0; c < channels_; ++c) {
                    const uint8_t *p = data + f * frameBytes + static_cast<size_t>(c) * static_cast<size_t>(bps);
                    sum += SampleToFloat(p, fmt_);
                }
                pending_.push_back(sum / static_cast<float>(channels_));
            }
        }
    }

    int32_t inRate_ = OUT_SAMPLE_RATE;
    int32_t channels_ = OUT_CHANNELS;
    int32_t fmt_ = SAMPLE_S16LE;
    double step_ = 1.0;
    double pos_ = 0.0;
    std::vector<float> pending_;
};

struct DecodeContext {
    std::mutex mtx;
    std::condition_variable cv;
    std::vector<std::pair<uint32_t, OH_AVBuffer *>> inputQueue;
    std::atomic<bool> hasError{false};
    std::atomic<bool> outputEos{false};
    int32_t errorCode = 0;

    std::mutex sinkMtx;
    FILE *outFile = nullptr;
    PcmResampler resampler;
    int32_t fallbackRate = OUT_SAMPLE_RATE;
    int32_t fallbackChannels = OUT_CHANNELS;
    int32_t fallbackFmt = SAMPLE_S16LE;
};

void OnError(OH_AVCodec *codec, int32_t errorCode, void *userData)
{
    (void)codec;
    DecodeContext *ctx = static_cast<DecodeContext *>(userData);
    ctx->errorCode = errorCode;
    ctx->hasError = true;
    ctx->cv.notify_all();
}

void OnStreamChanged(OH_AVCodec *codec, OH_AVFormat *format, void *userData)
{
    (void)codec;
    (void)format;
    (void)userData;
}

void OnNeedInputBuffer(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer, void *userData)
{
    (void)codec;
    DecodeContext *ctx = static_cast<DecodeContext *>(userData);
    {
        std::lock_guard<std::mutex> lock(ctx->mtx);
        ctx->inputQueue.emplace_back(index, buffer);
    }
    ctx->cv.notify_all();
}

void OnNewOutputBuffer(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer, void *userData)
{
    DecodeContext *ctx = static_cast<DecodeContext *>(userData);
    if (!ctx->resampler.configured) {
        OH_AVFormat *outFormat = OH_AudioCodec_GetOutputDescription(codec);
        int32_t rate = 0;
        int32_t channels = 0;
        int32_t sampleFmt = -1;
        if (outFormat != nullptr) {
            OH_AVFormat_GetIntValue(outFormat, OH_MD_KEY_AUD_SAMPLE_RATE, &rate);
            OH_AVFormat_GetIntValue(outFormat, OH_MD_KEY_AUD_CHANNEL_COUNT, &channels);
            OH_AVFormat_GetIntValue(outFormat, OH_MD_KEY_AUDIO_SAMPLE_FORMAT, &sampleFmt);
        }
        if (rate > 0 && channels > 0 && sampleFmt >= 0) {
            ctx->resampler.Configure(rate, channels, sampleFmt);
        } else {
            ctx->resampler.Configure(ctx->fallbackRate, ctx->fallbackChannels, ctx->fallbackFmt);
        }
    }
    OH_AVCodecBufferAttr attr;
    attr.pts = 0;
    attr.size = 0;
    attr.offset = 0;
    attr.flags = 0;
    bool attrOk = OH_AVBuffer_GetBufferAttr(buffer, &attr) == AV_ERR_OK;
    if (attrOk && attr.size > 0) {
        uint8_t *addr = OH_AVBuffer_GetAddr(buffer);
        if (addr != nullptr) {
            std::vector<int16_t> pcm;
            ctx->resampler.Process(addr + attr.offset, static_cast<size_t>(attr.size), pcm);
            if (!pcm.empty()) {
                std::lock_guard<std::mutex> lock(ctx->sinkMtx);
                if (ctx->outFile != nullptr) {
                    size_t written = fwrite(pcm.data(), sizeof(int16_t), pcm.size(), ctx->outFile);
                    (void)written;
                }
            }
        }
    }
    if ((attr.flags & AVCODEC_BUFFER_FLAGS_EOS) != 0) {
        ctx->outputEos = true;
        ctx->cv.notify_all();
    }
    OH_AudioCodec_FreeOutputBuffer(codec, index);
}

struct DecodeResult {
    bool ok = false;
    int32_t code = 0;
    std::string message;
    double durationMs = 0.0;
};

DecodeResult DecodeAudioFileToPcm(const std::string &inputPath, const std::string &outputPath)
{
    DecodeResult result;
    int fd = -1;
    OH_AVSource *source = nullptr;
    OH_AVFormat *sourceFormat = nullptr;
    OH_AVFormat *trackFormat = nullptr;
    OH_AVDemuxer *demuxer = nullptr;
    OH_AVCodec *codec = nullptr;
    OH_AVBuffer *scratch = nullptr;
    FILE *outFile = nullptr;
    DecodeContext *ctx = nullptr;
    bool pipelineStarted = false;

    do {
        fd = open(inputPath.c_str(), O_RDONLY);
        if (fd < 0) {
            result.code = DECODE_ERR_OPEN_FILE;
            result.message = "无法打开音频文件";
            break;
        }
        struct stat st;
        memset(&st, 0, sizeof(st));
        if (fstat(fd, &st) != 0 || st.st_size <= 0) {
            result.code = DECODE_ERR_OPEN_FILE;
            result.message = "音频文件无效";
            break;
        }

        source = OH_AVSource_CreateWithFD(fd, 0, static_cast<int64_t>(st.st_size));
        if (source == nullptr) {
            result.code = DECODE_ERR_PARSE_FILE;
            result.message = "无法解析音频文件，可能是不支持的格式";
            break;
        }
        sourceFormat = OH_AVSource_GetSourceFormat(source);
        int32_t trackCount = 0;
        if (sourceFormat == nullptr || !OH_AVFormat_GetIntValue(sourceFormat, OH_MD_KEY_TRACK_COUNT, &trackCount)) {
            result.code = DECODE_ERR_PARSE_FILE;
            result.message = "无法读取音频轨道信息";
            break;
        }
        int32_t audioTrack = -1;
        for (int32_t i = 0; i < trackCount; ++i) {
            OH_AVFormat *tf = OH_AVSource_GetTrackFormat(source, static_cast<uint32_t>(i));
            if (tf == nullptr) {
                continue;
            }
            int32_t trackType = -1;
            if (OH_AVFormat_GetIntValue(tf, OH_MD_KEY_TRACK_TYPE, &trackType) && trackType == MEDIA_TYPE_AUD) {
                audioTrack = i;
                trackFormat = tf;
                break;
            }
            OH_AVFormat_Destroy(tf);
        }
        if (audioTrack < 0 || trackFormat == nullptr) {
            result.code = DECODE_ERR_NO_AUDIO_TRACK;
            result.message = "未找到音频轨道";
            break;
        }

        const char *mime = nullptr;
        int32_t srcRate = 0;
        int32_t srcChannels = 0;
        int32_t srcFmt = -1;
        OH_AVFormat_GetStringValue(trackFormat, OH_MD_KEY_CODEC_MIME, &mime);
        OH_AVFormat_GetIntValue(trackFormat, OH_MD_KEY_AUD_SAMPLE_RATE, &srcRate);
        OH_AVFormat_GetIntValue(trackFormat, OH_MD_KEY_AUD_CHANNEL_COUNT, &srcChannels);
        OH_AVFormat_GetIntValue(trackFormat, OH_MD_KEY_AUDIO_SAMPLE_FORMAT, &srcFmt);
        if (mime == nullptr) {
            result.code = DECODE_ERR_BAD_FORMAT;
            result.message = "音频编码格式无法识别";
            break;
        }

        demuxer = OH_AVDemuxer_CreateWithSource(source);
        if (demuxer == nullptr) {
            result.code = DECODE_ERR_PARSE_FILE;
            result.message = "创建解复用器失败";
            break;
        }
        if (OH_AVDemuxer_SelectTrackByID(demuxer, static_cast<uint32_t>(audioTrack)) != AV_ERR_OK) {
            result.code = DECODE_ERR_PARSE_FILE;
            result.message = "选择音频轨道失败";
            break;
        }

        codec = OH_AudioCodec_CreateByMime(mime, false);
        if (codec == nullptr) {
            result.code = DECODE_ERR_CODEC_CREATE;
            result.message = "设备不支持该音频格式的解码";
            break;
        }

        outFile = fopen(outputPath.c_str(), "wb");
        if (outFile == nullptr) {
            result.code = DECODE_ERR_OUTPUT_FILE;
            result.message = "无法创建临时转写文件";
            break;
        }

        ctx = new DecodeContext();
        ctx->outFile = outFile;
        ctx->fallbackRate = (srcRate > 0) ? srcRate : OUT_SAMPLE_RATE;
        ctx->fallbackChannels = (srcChannels > 0) ? srcChannels : OUT_CHANNELS;
        ctx->fallbackFmt = (srcFmt >= 0) ? srcFmt : SAMPLE_S16LE;

        OH_AVCodecCallback callbacks;
        callbacks.onError = OnError;
        callbacks.onStreamChanged = OnStreamChanged;
        callbacks.onNeedInputBuffer = OnNeedInputBuffer;
        callbacks.onNewOutputBuffer = OnNewOutputBuffer;
        if (OH_AudioCodec_RegisterCallback(codec, callbacks, ctx) != AV_ERR_OK) {
            result.code = DECODE_ERR_CODEC_SETUP;
            result.message = "注册解码回调失败";
            break;
        }
        if (OH_AudioCodec_Configure(codec, trackFormat) != AV_ERR_OK) {
            result.code = DECODE_ERR_CODEC_SETUP;
            result.message = "解码器配置失败";
            break;
        }
        if (OH_AudioCodec_Prepare(codec) != AV_ERR_OK) {
            result.code = DECODE_ERR_CODEC_SETUP;
            result.message = "解码器准备失败";
            break;
        }
        if (OH_AudioCodec_Start(codec) != AV_ERR_OK) {
            result.code = DECODE_ERR_CODEC_SETUP;
            result.message = "解码器启动失败";
            break;
        }
        pipelineStarted = true;

        scratch = OH_AVBuffer_Create(static_cast<int32_t>(DEMUX_SCRATCH_CAPACITY));
        if (scratch == nullptr) {
            result.code = DECODE_ERR_NO_MEMORY;
            result.message = "内存不足";
            break;
        }

        bool inputEosSent = false;
        bool loopBroken = false;
        while (!inputEosSent && !ctx->hasError) {
            OH_AVCodecBufferAttr attr;
            attr.pts = 0;
            attr.size = 0;
            attr.offset = 0;
            attr.flags = 0;
            bool sendEos = false;
            OH_AVErrCode readRet = OH_AVDemuxer_ReadSampleBuffer(demuxer, static_cast<uint32_t>(audioTrack),
                scratch);
            if (readRet == AV_ERR_OK) {
                OH_AVBuffer_GetBufferAttr(scratch, &attr);
                if (attr.size < 0) {
                    attr.size = 0;
                }
                if ((attr.flags & AVCODEC_BUFFER_FLAGS_EOS) != 0) {
                    sendEos = true;
                }
            } else {
                attr.size = 0;
                attr.flags = AVCODEC_BUFFER_FLAGS_EOS;
                sendEos = true;
            }

            OH_AVBuffer *inBuf = nullptr;
            uint32_t inIndex = 0;
            {
                std::unique_lock<std::mutex> lock(ctx->mtx);
                bool got = ctx->cv.wait_for(lock, std::chrono::milliseconds(STALL_TIMEOUT_MS), [&ctx] {
                    return !ctx->inputQueue.empty() || ctx->hasError.load();
                });
                if (!got) {
                    result.code = DECODE_ERR_TIMEOUT;
                    result.message = "解码超时";
                    loopBroken = true;
                    break;
                }
                if (ctx->hasError) {
                    loopBroken = true;
                    break;
                }
                inIndex = ctx->inputQueue.front().first;
                inBuf = ctx->inputQueue.front().second;
                ctx->inputQueue.erase(ctx->inputQueue.begin());
            }
            if (inBuf == nullptr) {
                continue;
            }

            if (attr.size > 0) {
                int32_t capacity = OH_AVBuffer_GetCapacity(inBuf);
                uint8_t *dst = OH_AVBuffer_GetAddr(inBuf);
                uint8_t *src = OH_AVBuffer_GetAddr(scratch);
                if (dst == nullptr || src == nullptr || attr.size > capacity) {
                    result.code = DECODE_ERR_DECODE;
                    result.message = "解码缓冲区异常";
                    loopBroken = true;
                    break;
                }
                memcpy(dst, src + attr.offset, static_cast<size_t>(attr.size));
            }
            OH_AVBuffer_SetBufferAttr(inBuf, &attr);
            OH_AudioCodec_PushInputBuffer(codec, inIndex);
            if (sendEos) {
                inputEosSent = true;
            }
        }
        if (loopBroken) {
            break;
        }
        if (ctx->hasError) {
            result.code = DECODE_ERR_DECODE;
            result.message = "解码失败，错误码 " + std::to_string(ctx->errorCode);
            break;
        }

        {
            std::unique_lock<std::mutex> lock(ctx->mtx);
            bool done = ctx->cv.wait_for(lock, std::chrono::milliseconds(STALL_TIMEOUT_MS), [&ctx] {
                return ctx->outputEos.load() || ctx->hasError.load();
            });
            if (!done) {
                result.code = DECODE_ERR_TIMEOUT;
                result.message = "解码输出超时";
                break;
            }
        }
        if (ctx->hasError) {
            result.code = DECODE_ERR_DECODE;
            result.message = "解码失败，错误码 " + std::to_string(ctx->errorCode);
            break;
        }

        {
            std::lock_guard<std::mutex> lock(ctx->sinkMtx);
            if (fflush(outFile) != 0) {
                result.code = DECODE_ERR_OUTPUT_FILE;
                result.message = "写入转写文件失败";
                break;
            }
        }
        // 16kHz × 16bit 单声道：32 字节 / 毫秒；字节数在关闭文件前统一按文件大小统计
        result.ok = true;
    } while (false);

    // 统计输出字节数（在关闭文件前重新查询文件大小，避免多线程计数）
    if (outFile != nullptr) {
        struct stat outSt;
        memset(&outSt, 0, sizeof(outSt));
        if (result.ok && stat(outputPath.c_str(), &outSt) == 0) {
            result.durationMs = static_cast<double>(outSt.st_size) / 32.0;
        }
        fclose(outFile);
    }
    if (ctx != nullptr) {
        if (pipelineStarted) {
            OH_AudioCodec_Stop(codec);
        }
        delete ctx;
    }
    if (scratch != nullptr) {
        OH_AVBuffer_Destroy(scratch);
    }
    if (codec != nullptr) {
        OH_AudioCodec_Destroy(codec);
    }
    if (demuxer != nullptr) {
        OH_AVDemuxer_Destroy(demuxer);
    }
    if (trackFormat != nullptr) {
        OH_AVFormat_Destroy(trackFormat);
    }
    if (sourceFormat != nullptr) {
        OH_AVFormat_Destroy(sourceFormat);
    }
    if (source != nullptr) {
        OH_AVSource_Destroy(source);
    }
    if (fd >= 0) {
        close(fd);
    }
    return result;
}

struct AsyncWorkData {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    std::string inputPath;
    std::string outputPath;
    bool ok = false;
    double durationMs = 0.0;
    int32_t code = 0;
    std::string message;
};

bool GetJsString(napi_env env, napi_value value, std::string &out)
{
    size_t len = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &len) != napi_ok) {
        return false;
    }
    std::vector<char> buf(len + 1);
    size_t written = 0;
    if (napi_get_value_string_utf8(env, value, buf.data(), buf.size(), &written) != napi_ok) {
        return false;
    }
    out.assign(buf.data(), written);
    return true;
}

void ExecuteWork(napi_env env, void *data)
{
    (void)env;
    AsyncWorkData *d = static_cast<AsyncWorkData *>(data);
    DecodeResult r = DecodeAudioFileToPcm(d->inputPath, d->outputPath);
    d->ok = r.ok;
    d->durationMs = r.durationMs;
    d->code = r.code;
    d->message = r.message;
}

void CompleteWork(napi_env env, napi_status status, void *data)
{
    AsyncWorkData *d = static_cast<AsyncWorkData *>(data);
    if (d->ok) {
        napi_value duration = nullptr;
        napi_create_double(env, d->durationMs, &duration);
        napi_resolve_deferred(env, d->deferred, duration);
    } else {
        napi_value code = nullptr;
        napi_value msg = nullptr;
        napi_value error = nullptr;
        napi_create_int32(env, d->code, &code);
        napi_create_string_utf8(env, d->message.c_str(), NAPI_AUTO_LENGTH, &msg);
        napi_create_error(env, code, msg, &error);
        napi_reject_deferred(env, d->deferred, error);
    }
    napi_delete_async_work(env, d->work);
    delete d;
}

napi_value DecodeAudioToPcm(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc < 2) {
        napi_throw_type_error(env, nullptr, "decodeAudioToPcm(inputPath: string, outputPath: string)");
        return nullptr;
    }
    AsyncWorkData *data = new AsyncWorkData();
    if (!GetJsString(env, args[0], data->inputPath) || !GetJsString(env, args[1], data->outputPath)) {
        delete data;
        napi_throw_type_error(env, nullptr, "decodeAudioToPcm 参数必须是字符串");
        return nullptr;
    }

    napi_value promise = nullptr;
    napi_create_promise(env, &data->deferred, &promise);
    napi_value resourceName = nullptr;
    napi_create_string_utf8(env, "decodeAudioToPcm", NAPI_AUTO_LENGTH, &resourceName);
    napi_create_async_work(env, nullptr, resourceName, ExecuteWork, CompleteWork, data, &data->work);
    napi_queue_async_work(env, data->work);
    return promise;
}

} // namespace

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        {"decodeAudioToPcm", nullptr, DecodeAudioToPcm, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module transcribeModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "entry",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterTranscribeModule(void)
{
    napi_module_register(&transcribeModule);
}
