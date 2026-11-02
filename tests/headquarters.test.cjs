'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const {Game}=require('../engine.js');

test('новая игра создаёт одно готовое главное здание 2×2 и первых жителей',()=>{
  const g=new Game(1729,'settlement'),hq=g.warehouse();
  assert.equal(g.buildings.length,1);
  assert.equal(hq.type,'warehouse');
  assert.deepEqual(hq.size,{w:2,h:2});
  assert.deepEqual(hq.headquarters,{level:1});
  assert.equal(g.siteAt(10,8),null);
  assert.equal(g.buildingAt(11,9),hq);
  assert.equal(g.population,8);
  assert.equal(g.availableWorkers(),4);
  assert.equal(g.populationCapacity(),8);
  assert.equal(g.build('warehouse',19,9).ok,false);
});
test('граница запрещает стройки, дороги и поля вне поселения',()=>{
  const g=new Game(1729,'settlement');
  assert.equal(g.territoryAt(12,9),true);
  assert.equal(g.territoryAt(25,15),false);
  assert.equal(g.build('house',24,14).ok,false);
  assert.equal(g.build('road',24,14).ok,false);
  assert.equal(g.placeField(24,14).ok,false);
  assert.equal(g.build('logger',12,9).ok,true);
  assert.equal(g.build('quarry',16,9).ok,true);
});
test('многоклеточная постройка должна целиком помещаться в поселении',()=>{
  const g=new Game(1729,'settlement');
  assert.equal(g.territoryAt(20,9),true);
  assert.equal(g.territoryAt(21,9),false);
  assert.equal(g.build('mill',20,9).ok,false);
});
test('жилые дома увеличивают лимит, главное здание сохраняется',()=>{
  const g=new Game(1729,'settlement');
  const site=g.build('house',13,11);
  assert.equal(site.ok,true);
  g.finishSite(site.site);
  assert.equal(g.populationCapacity(),14);
  const restored=Game.restore(g.save());
  assert.ok(restored);
  assert.equal(restored.warehouse().headquarters.level,1);
  assert.deepEqual(restored.warehouse().size,{w:2,h:2});
  assert.equal(restored.populationCapacity(),14);
  assert.equal(restored.build('warehouse',16,7).ok,false);
});
