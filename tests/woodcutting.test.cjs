'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');

const root=path.join(__dirname,'..','assets','characters','logger');
const manifest=JSON.parse(fs.readFileSync(path.join(root,'manifest.json'),'utf8'));

function sizeOfWebP(filename){
  const data=fs.readFileSync(path.join(root,filename));
  assert.equal(data.toString('ascii',0,4),'RIFF');
  assert.equal(data.toString('ascii',8,12),'WEBP');
  assert.equal(data.toString('ascii',12,16),'VP8X');
  return {width:data.readUIntLE(24,3)+1,
    height:data.readUIntLE(27,3)+1,bytes:data.length};
}

test('все четыре состояния лесоруба имеют растровые кадры 4×8',()=>{
  assert.deepEqual(manifest.directions,['se','sw','ne','nw']);
  assert.equal(manifest.frameWidth,96);
  assert.equal(manifest.frameHeight,144);
  assert.equal(manifest.framesPerDirection,8);
  assert.deepEqual(Object.keys(manifest.states),
    ['idle','walk','fell_tree','carry_logs']);
  for(const [state,filename] of Object.entries(manifest.states)){
    const dim=sizeOfWebP(filename);
    assert.equal(dim.width,768,state);
    assert.equal(dim.height,576,state);
    assert.ok(dim.bytes>2000,state);
  }
});

test('модульный атлас сохранён отдельно от готовых кадров',()=>{
  const dim=sizeOfWebP(manifest.moduleAtlas);
  assert.equal(dim.width,768);
  assert.equal(dim.height,384);
});

test('рубка использует настоящую рабочую фазу и не рисует топор кодом',()=>{
  assert.equal(manifest.phase.work,'fell_tree');
  assert.equal(manifest.phase.return,'carry_logs');
  const ui=fs.readFileSync(path.join(__dirname,'..','ui.js'),'utf8');
  assert.match(ui,/loggerAtlasReady/);
  assert.match(ui,/loggerRasterDrawCount/);
  assert.doesNotMatch(ui,/Woodcutting\.draw|Woodcutting\.chips/);
  assert.doesNotMatch(ui,/ctx\.quadraticCurveTo.*[Aa]xe/);
});
