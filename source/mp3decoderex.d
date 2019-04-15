module mp3decoderex;

public import mp3decoder;

struct mp3dec_file_info_t {
	mp3d_sample_t* buffer;
	size_t samples; /* channels included, byte size = samples*sizeof(short) */
	int channels, hz, layer, avg_bitrate_kbps;
}

alias MP3D_PROGRESS_CB = int function(void* user_data, size_t file_size, size_t offset, ref mp3dec_frame_info_t info);

alias MP3D_ITERATE_CB = int function(void* user_data, ref const(ubyte)* frame, int frame_size, size_t offset, ref mp3dec_frame_info_t info);

mp3dec_file_info_t mp3dec_load(ref mp3dec_t dec, string file_name, MP3D_PROGRESS_CB progress_cb, void* user_data) {
	import std.mmfile;
	auto file = new MmFile(file_name, MmFile.Mode.read, 0, null, 0);
	scope (exit) {
		file.destroy();
	}
	mp3dec_file_info_t info;
	mp3dec_load_buf(dec, cast(ubyte[]) file[0 .. $], info, progress_cb, user_data);
	return info;
}

int mp3dec_iterate(string file_name, MP3D_ITERATE_CB callback, void* user_data) {
	import std.mmfile;
	auto file = new MmFile(file_name, MmFile.Mode.read, 0, null, 0);
	scope (exit) {
		file.destroy();
	}
	mp3dec_iterate_buf(cast(ubyte[]) file[0 .. $], callback, user_data);
	return 0;
}

private size_t mp3dec_skip_id3v2(const(ubyte)* buf, size_t buf_size) {
	import core.stdc.string : strncmp;
	if (buf_size > 10 && !strncmp(cast(char*) buf, "ID3", 3)) {
		return (((buf[6] & 0x7f) << 21) | ((buf[7] & 0x7f) << 14) | ((buf[8] & 0x7f) << 7) | (buf[9] & 0x7f)) + 10;
	}
	return 0;
}

private void mp3dec_load_buf(ref mp3dec_t dec, const(ubyte)[] buffer, ref mp3dec_file_info_t info, MP3D_PROGRESS_CB progress_cb, void* user_data) {
	import core.stdc.string : memcpy, memset;
	import core.stdc.stdlib : malloc, realloc;
	auto buf_size = buffer.length;
	auto buf = buffer.ptr;
	size_t orig_buf_size = buf_size;
	mp3d_sample_t[MINIMP3_MAX_SAMPLES_PER_FRAME] pcm;
	mp3dec_frame_info_t frame_info;
	memset(&info, 0, info.sizeof);
	memset(&frame_info, 0, frame_info.sizeof);
	/* skip id3v2 */
	size_t id3v2size = mp3dec_skip_id3v2(buf, buf_size);
	if (id3v2size > buf_size)
		return;
	buf += id3v2size;
	buf_size -= id3v2size;
	/* try to make allocation size assumption by first frame */
	mp3dec_init(dec);
	int samples;
	do {
		samples = mp3dec_decode_frame(dec, buf, cast(int) buf_size, pcm.ptr, &frame_info);
		buf += frame_info.frame_bytes;
		buf_size -= frame_info.frame_bytes;
		if (samples)
			break;
	}
	while (frame_info.frame_bytes);
	if (!samples)
		return;
	samples *= frame_info.channels;
	size_t allocated = (buf_size / frame_info.frame_bytes) * samples * mp3d_sample_t.sizeof + MINIMP3_MAX_SAMPLES_PER_FRAME * mp3d_sample_t.sizeof;
	info.buffer = cast(mp3d_sample_t*) malloc(allocated);
	if (!info.buffer)
		return;
	info.samples = samples;
	memcpy(info.buffer, pcm.ptr, info.samples * mp3d_sample_t.sizeof);
	/* save info */
	info.channels = frame_info.channels;
	info.hz = frame_info.hz;
	info.layer = frame_info.layer;
	size_t avg_bitrate_kbps = frame_info.bitrate_kbps;
	size_t frames = 1;
	/* decode rest frames */
	int frame_bytes;
	do {
		if ((allocated - info.samples * mp3d_sample_t.sizeof) < MINIMP3_MAX_SAMPLES_PER_FRAME * mp3d_sample_t.sizeof) {
			allocated *= 2;
			info.buffer = cast(mp3d_sample_t*) realloc(info.buffer, allocated);
		}
		samples = mp3dec_decode_frame(dec, buf, cast(int) buf_size, info.buffer + info.samples, &frame_info);
		frame_bytes = frame_info.frame_bytes;
		buf += frame_bytes;
		buf_size -= frame_bytes;
		if (samples) {
			if (info.hz != frame_info.hz || info.layer != frame_info.layer)
				break;
			if (info.channels && info.channels != frame_info.channels) {
				version (MINIMP3_ALLOW_MONO_STEREO_TRANSITION) {
					info.channels = 0; /* mark file with mono-stereo transition */
				}
				else {
					break;
				}
			}
			info.samples += samples * frame_info.channels;
			avg_bitrate_kbps += frame_info.bitrate_kbps;
			frames++;
			if (progress_cb)
				progress_cb(user_data, orig_buf_size, orig_buf_size - buf_size, frame_info);
		}
	}
	while (frame_bytes);
	/* reallocate to normal buffer size */
	if (allocated != info.samples * mp3d_sample_t.sizeof)
		info.buffer = cast(mp3d_sample_t*) realloc(info.buffer, info.samples * mp3d_sample_t.sizeof);
	info.avg_bitrate_kbps = cast(int)(avg_bitrate_kbps / frames);
}

private void mp3dec_iterate_buf(const(ubyte)[] buffer, MP3D_ITERATE_CB callback, void* user_data) {
	import core.stdc.string : memset;
	auto buf_size = buffer.length;
	auto buf = buffer.ptr;
	if (!callback)
		return;
	mp3dec_frame_info_t frame_info;
	memset(&frame_info, 0, frame_info.sizeof);
	/* skip id3v2 */
	size_t id3v2size = mp3dec_skip_id3v2(buf, buf_size);
	if (id3v2size > buf_size)
		return;
	const(ubyte)* orig_buf = buf;
	buf += id3v2size;
	buf_size -= id3v2size;
	do {
		int free_format_bytes = 0, frame_size = 0;
		int i = mp3d_find_frame(buf, cast(int) buf_size, &free_format_bytes, &frame_size);
		buf += i;
		buf_size -= i;
		if (i && !frame_size)
			continue;
		if (!frame_size)
			break;
		const(ubyte)* hdr = buf;
		frame_info.channels = HDR_IS_MONO(hdr) ? 1 : 2;
		frame_info.hz = hdr_sample_rate_hz(hdr);
		frame_info.layer = 4 - HDR_GET_LAYER(hdr);
		frame_info.bitrate_kbps = hdr_bitrate_kbps(hdr);
		frame_info.frame_bytes = frame_size;

		if (callback(user_data, hdr, frame_size, hdr - orig_buf, frame_info))
			break;
		buf += frame_size;
		buf_size -= frame_size;
	}
	while (1);
}
