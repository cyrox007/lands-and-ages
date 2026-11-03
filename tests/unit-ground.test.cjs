'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const Ground=require('../unit-ground.js');
const fs=require('node:fs');
const path=require('node:path');

const near=(a,b)=>Math.abs(a-b)<.000001;

test('все форматы персонажей ставят реальные ступни в одну точку земли',()=>{
  for(const kind of Object.keys(Ground.RASTER)){
    for(const zoom of [.65,1,2.08,3]){
      const p={x:217.43,y:189.72},width=82*.48*zoom;
      const rect=Ground.spriteRect(p.x,p.y,width,kind);
      const foot=Ground.footAt(rect,kind);
      assert.ok(near(foot.x,p.x),kind);
      assert.ok(near(foot.y,p.y),kind);
      assert.ok(rect.height>0);
      assert.ok(rect.y<p.y);
    }
  }
});

test('тень находится под ступнями независимо от масштаба',()=>{
  for(const scale of [.22,.3,.34,.45]){
    const p={x:125.7,y:328.1};
    const rect=Ground.shadowRect(p.x,p.y,170,85,scale);
    assert.ok(near(rect.x+rect.width/2,p.x));
    assert.ok(near(rect.y+rect.height/2,p.y));
    assert.ok(rect.width>rect.height);
  }
});

test('кадры не меняют высоту ног при выборе направления или состояния',()=>{
  const frame=Ground.RASTER.logger;
  assert.deepEqual(frame,{width:96,height:144,foot:140});
  for(const state of ['idle','walk','fell_tree','carry_logs']){
    for(const direction of ['se','sw','ne','nw']){
      const rect=Ground.spriteRect(31,72,50,'logger');
      assert.ok(near(Ground.footAt(rect,'logger').y,72),
        state+':'+direction);
    }
  }
});

test('все автономные рабочие и свободные жители используют одну точку опоры',()=>{
  const ui=fs.readFileSync(path.join(__dirname,'..','ui.js'),'utf8');
  const draw=ui.slice(ui.indexOf('  function drawBuilder('),
    ui.indexOf('  function drawPlacementPreview('));
  const villager=ui.slice(ui.indexOf('  function drawVillager('),
    ui.indexOf('  function paintMillSprite('));
  assert.match(draw,/const footY=p\.y;/);
  assert.match(draw,/workerSprite\(a,role,p\.x,p\.y,t\*\.44\)/);
  assert.match(draw,/castUnitShadow\(p\.x,p\.y,t,h/);
  assert.match(villager,/castUnitShadow\(p\.x,p\.y,t,h/);
  assert.match(villager,/paintedSprite\(person\.variant,p\.x,p\.y,t\*\.49/);
  assert.doesNotMatch(draw,/workerSprite\(a,role,p\.x,p\.y\+h/);
  assert.doesNotMatch(draw,/castShadow\(p\.x,footY/);
});

test('персонал зданий больше не рисуется внутри занятых клеток',()=>{
  const ui=fs.readFileSync(path.join(__dirname,'..','ui.js'),'utf8');
  const block=ui.slice(ui.indexOf("    if(game.scenario==='settlement'&&(game.staff"),
    ui.indexOf('    if(!connected){',ui.indexOf("    if(game.scenario==='settlement'&&(game.staff")));
  assert.match(block,/game\.entrance\(b\)/);
  assert.match(block,/game\.walkable\(entry\.x,entry\.y\)/);
  assert.doesNotMatch(block,/screen\(b\.x\+\.91,b\.y\+\.79\)/);
});
