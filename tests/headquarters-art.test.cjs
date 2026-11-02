'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const root=path.join(__dirname,'..');

function checkImage(relative){
  const bytes=fs.readFileSync(path.join(root,relative));
  assert.ok(bytes.length>1000,relative);
  assert.equal(bytes.subarray(0,4).toString('ascii'),'RIFF',relative);
  assert.equal(bytes.subarray(8,12).toString('ascii'),'WEBP',relative);
}

test('Главное здание: все состояния и модули доступны как WebP',()=>{
  const m=require('../assets/headquarters/manifest.json');
  for(const file of [m.ready,...m.construction,...m.damage,...m.modules])
    checkImage('assets/headquarters/'+file);
  const source=fs.readFileSync(path.join(root,'assets/headquarters',m.source));
  assert.equal(source.subarray(1,4).toString('ascii'),'PNG');
});
test('Рабочие: пять профессий и опорный кадр ходьбы',()=>{
  const m=require('../assets/workers/manifest.json');
  for(const file of [...Object.values(m.roles),m.prototypeWalk.path])
    checkImage('assets/workers/'+file);
  assert.equal(m.prototypeWalk.productionReady,false);
  assert.deepEqual(m.animationContract.directions,['se','sw','ne','nw']);
  assert.equal(m.animationContract.walkFrames,8);
  const source=fs.readFileSync(path.join(root,'assets/workers',m.source));
  assert.equal(source.subarray(1,4).toString('ascii'),'PNG');
});
