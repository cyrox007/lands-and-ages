'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path');

const root=path.join(__dirname,'..');
const art=JSON.parse(fs.readFileSync(path.join(root,'assets/buildings/headquarters/manifest.json'),'utf8'));

test('Главное здание имеет четыре уровня и исходные художественные файлы',()=>{
  assert.equal(art.engineType,'warehouse');
  assert.equal(Object.keys(art.levels).length,4);
  for(const filename of Object.values(art.levels)){
    const bytes=fs.readFileSync(path.join(root,'assets/buildings/headquarters',filename));
    assert.equal(bytes.subarray(0,4).toString(),'RIFF');
    assert.equal(bytes.subarray(8,12).toString(),'WEBP');
  }
  for(const p of art.sources)assert.ok(fs.statSync(path.join(root,p)).size>100000,p);
});

test('Строительные стадии и новые профессии имеют прозрачные изображения',()=>{
  assert.equal(art.construction.length,5);
  assert.equal(art.workers.length,5);
  for(const name of art.workers){
    const file=fs.readFileSync(path.join(root,'assets/workers',name));
    assert.equal(file.subarray(8,12).toString(),'WEBP');
  }
  assert.deepEqual(art.motionReference.frames,8);
  assert.equal(art.motionReference.status,'reference-only');
});
