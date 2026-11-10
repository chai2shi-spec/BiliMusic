/**
 * libentry.so 类型声明：本机音频解码（转写前置）。
 * 输入音频文件（m4a / mp3 / flac 等），输出 16kHz / 单声道 / 16bit 小端 PCM 文件。
 * resolve：PCM 时长（毫秒）；reject：BusinessError，code 为原生侧错误码，message 为中文原因。
 */
export const decodeAudioToPcm: (inputPath: string, outputPath: string) => Promise<number>;
