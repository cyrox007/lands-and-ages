const test = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');

test('Прозрачный атлас ресурсов содержит десять кадров 24×24', () => {
  const data = readFileSync(join(__dirname, '../assets/resource-atlas.webp'));
  assert.equal(data.subarray(0, 4).toString(), 'RIFF');
  assert.equal(data.subarray(8, 16).toString(), 'WEBPVP8X');
  assert.equal(data.readUIntLE(24, 3) + 1, 5 * 24);
  assert.equal(data.readUIntLE(27, 3) + 1, 2 * 24);
  assert.ok(data[20] & 0x10, 'В атласе необходим прозрачный фон');
});
