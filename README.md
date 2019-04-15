# mp3decoder
mp3decoder is based on minimp3 (https://github.com/lieff/minimp3)

# Example Usage
```
module mp3towav;

public import mp3decoder;
public import mp3decoderex;
import core.stdc.string;
import core.stdc.stdlib;
import std.stdio;
import std.typecons;

auto decode(string input_file_name) {
	mp3dec_t mp3d;
	mp3dec_file_info_t info = mp3dec_load(mp3d, input_file_name, null, null);
	auto r = info.buffer[0 .. info.samples].dup;
	free(info.buffer);
	return tuple!("samplerate", "channelcount", "buffer")(info.hz, info.channels, r);
}

void toWaveFile(Tuple!(int, "samplerate", int, "channelcount", short[], "buffer") input, string filepath) {
	import std.stdio;

	char[] wav_header(int hz, int ch, int bips, int data_bytes) @nogc {
		static char[44] hdr = "RIFFsizeWAVEfmt \x10\0\0\0\1\0ch_hz_abpsbabsdatasize";
		ulong nAvgBytesPerSec = bips * ch * hz >> 3;
		uint nBlockAlign = bips * ch >> 3;
		*cast(int*)(hdr.ptr + 0x04) = 44 + data_bytes - 8; /* File size - 8 */
		*cast(short*)(hdr.ptr + 0x14) = 1; /* Integer PCM format */
		*cast(short*)(hdr.ptr + 0x16) = cast(short) ch;
		*cast(int*)(hdr.ptr + 0x18) = hz;
		*cast(int*)(hdr.ptr + 0x1C) = cast(int) nAvgBytesPerSec;
		*cast(short*)(hdr.ptr + 0x20) = cast(short) nBlockAlign;
		*cast(short*)(hdr.ptr + 0x22) = cast(short) bips;
		*cast(int*)(hdr.ptr + 0x28) = data_bytes;
		return hdr;
	}

	auto f = File(filepath, "wb");
	f.rawWrite(wav_header(0, 0, 0, 0));
	if (input.buffer.length) {
		f.rawWrite(input.buffer);
	}
	auto data_bytes = f.tell() - 44;
	if (data_bytes > int.max) {
		throw new Exception("can only store int.max values in wav");
	}
	f.rewind();
	f.rawWrite(wav_header(input.samplerate, input.channelcount, 16, cast(int) data_bytes));
	f.flush();
	f.sync();
	f.close();
}
```
