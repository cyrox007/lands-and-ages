'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path');
const Art=require('../resource-pack.js');
const {Game}=require('../engine.js');

test('утверждённый атлас содержит 10 вариантов пяти ресурсов',()=>{
  assert.equal(Art.cell,320);
  const bytes=fs.readFileSync(path.join(__dirname,'../',Art.atlas));
  assert.equal(bytes.subarray(0,4).toString('ascii'),'RIFF');
  assert.equal(bytes.subarray(8,12).toString('ascii'),'WEBP');
  assert.ok(bytes.length>100000,'используется настоящий детализированный рисунок');
  assert.equal(Object.keys(Art.variants).length,5);
  const cells=new Set();
  for(const type of ['boards','stone','logs','grain','flour']){
    const one=Art.sprite(type,1),many=Art.sprite(type,3);
    assert.ok(one&&many&&one.x!==many.x||one?.y!==many?.y,type);
    for(const c of [one,many]){
      assert.equal(c.w,320);assert.equal(c.h,320);
      assert.ok(c.x>=0&&c.x<1600&&c.y>=0&&c.y<640);
      cells.add(c.x+':'+c.y);
    }
  }
  assert.equal(cells.size,10);
  assert.equal(Art.sprite('bread',1),null,'для хлеба пока остаётся прежний ассет');
});

test('без доставки на фундаменте нет ни досок, ни камня',()=>{
  const site={type:'mill',required:{boards:2,stone:1},goods:{boards:0,stone:0},
    progress:0,duration:15};
  const stages=Art.visibleMaterials(site);
  assert.deepEqual(stages.map(x=>x.visible),[0,0]);
  site.goods.boards=2;
  assert.deepEqual(Art.visibleMaterials(site).map(x=>x.visible),[2,0]);
  site.goods.stone=1;
  assert.deepEqual(Art.visibleMaterials(site).map(x=>x.visible),[2,1]);
});

test('материалы встраиваются в стены по реальному прогрессу',()=>{
  const site={type:'mill',required:{boards:4,stone:2},goods:{boards:4,stone:2},
    progress:0,duration:20};
  const sample=[];
  for(const progress of [0,5,10,15,20]){
    site.progress=progress;
    sample.push(Art.visibleMaterials(site).map(x=>x.visible));
  }
  assert.deepEqual(sample,[[4,2],[4,2],[3,2],[2,1],[0,0]]);
});

test('отображение не меняет физические запасы и останавливается на паузе',()=>{
  const g=new Game(1729,'settlement');
  assert.equal(g.build('mill',14,8).ok,true);
  const site=g.siteAt(14,8);site.goods.boards=2;site.goods.stone=0;
  const before=JSON.stringify(site);
  assert.deepEqual(Art.visibleMaterials(site).map(x=>x.visible),[2,0]);
  assert.equal(JSON.stringify(site),before,'рисунок не тратит ресурсы');
  g.setPaused?.(true);
  g.paused=true;g.step(15);
  assert.deepEqual(Art.visibleMaterials(site).map(x=>x.visible),[2,0]);
  assert.equal(JSON.stringify(site),before,'на паузе стройка остаётся неизменной');
});
