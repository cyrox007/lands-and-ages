extends RefCounted
## Общий безопасный декодер массивов физики в сохранении Godot.

static func decode_float32(encoded: String, count: int) -> PackedFloat32Array:
	var empty := PackedFloat32Array()
	if count < 0:
		return empty
	var byte_count := count * 4
	var expected_length := 4 * ceili(float(byte_count) / 3.0)
	if encoded.length() != expected_length:
		return empty
	var padding := (3 - byte_count % 3) % 3
	var chars: PackedByteArray = encoded.to_utf8_buffer()
	for i in range(chars.size()):
		var c: int = chars[i]
		if i >= chars.size() - padding:
			if c != 61:
				return empty
		elif not ((c >= 65 and c <= 90) or (c >= 97 and c <= 122)
				or (c >= 48 and c <= 57) or c == 43 or c == 47):
			return empty
	var raw: PackedByteArray = Marshalls.base64_to_raw(encoded)
	if raw.size() != byte_count:
		return empty
	return raw.to_float32_array()
