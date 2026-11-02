'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {Game,id}=require('../engine.js');
const run=(g,s)=>{for(let i=0;i<Math.ceil(s*10);i++)g.step(.1);};

test('мельница занимает всю площадку 2×2, другие здания пока 1×1',()=>{
  const g=new Game(1729,'settlement');
  assert.deepEqual(g.footprint('mill'),{w:2,h:2});
  for(const type of ['house','logger','quarry','farm','bakery','road','field'])
    assert.deepEqual(g.footprint(type),{w:1,h:1},type);
  assert.equal(g.placement('mill',14,8).ok,true);
  assert.deepEqual(g.placement('mill',14,8).cells.map(c=>[c.x,c.y]),
    [[14,8],[15,8],[14,9],[15,9]]);
});

test('нельзя строить мельницу на дороге, других зданиях и у края карты',()=>{
  const g=new Game(1729,'settlement');
  const funds=g.coins;
  const road=g.placement('mill',14,9);
  assert.equal(road.ok,false);
  assert.ok(road.cells.some(c=>!c.ok&&/дорог/.test(c.error)));
  assert.equal(g.build('mill',14,9).ok,false);
  assert.equal(g.coins,funds,'отклонённый заказ не списывает деньги');
  assert.equal(g.build('mill',11,9).ok,false,'склад занимает участок');
  assert.equal(g.placement('mill',25,17).ok,false);
  assert.equal(g.placement('mill',25,17).cells.length,4);
  assert.equal(g.build('mill',25,17).ok,false);
});

test('строительная площадка блокирует все четыре клетки до готовности',()=>{
  const g=new Game(1729,'settlement');
  assert.equal(g.build('mill',14,8).ok,true);
  const site=g.siteAt(14,8);
  assert.deepEqual(site.size,{w:2,h:2});
  for(const [x,y] of [[14,8],[15,8],[14,9],[15,9]]){
    assert.equal(g.siteAt(x,y).id,site.id);
    assert.equal(g.build('road',x,y).ok,false);
    assert.equal(g.build('house',x,y).ok,false);
    assert.equal(g.placeField(x,y).ok,false);
  }
  assert.ok(g.entrance(site),'дорога примыкает к периметру площадки');
  const snapshot=Game.restore(g.save());
  assert.ok(snapshot);
  assert.deepEqual(snapshot.siteAt(15,9).size,{w:2,h:2});
  assert.equal(snapshot.save(),g.save());
});

test('готовая мельница блокирует свою площадь и принимает носильщиков с края',()=>{
  const g=new Game(1729,'settlement');
  g.warehouse().goods.stone=4;
  assert.equal(g.build('mill',14,8).ok,true);
  run(g,90);
  const mill=g.buildingAt(14,8);
  assert.ok(mill,'строительство завершилось');
  assert.deepEqual(mill.size,{w:2,h:2});
  for(const [x,y] of [[14,8],[15,8],[14,9],[15,9]]){
    assert.equal(g.buildingAt(x,y).id,mill.id);
    assert.equal(g.build('road',x,y).ok,false);
  }
  const gate=g.entrance(mill);
  assert.ok(gate&&gate.y===10&&[14,15].includes(gate.x));
  assert.equal(g.connected(mill),true);
  const saved=Game.restore(g.save());
  assert.ok(saved);assert.equal(saved.save(),g.save());
});

test('полностью разрушенная мельница продолжает занимать всю площадку',()=>{
  const g=new Game(1729,'settlement');
  const mill=g.addBuilding('mill',18,8,{}, {w:2,h:2});
  assert.equal(g.damageMill(mill.id,100).ok,true);
  assert.equal(g.millState(mill).phase,'fresh_ruins');
  for(const [x,y] of [[18,8],[19,8],[18,9],[19,9]]){
    assert.equal(g.buildingAt(x,y).id,mill.id);
    assert.equal(g.build('road',x,y).ok,false);
  }
  assert.equal(g.placement('mill',19,8).ok,false);
});

test('старое сохранение сохраняет исходный одноклеточный размер здания',()=>{
  const g=new Game(1729,'settlement');
  const b=g.addBuilding('mill',20,8);
  const restored=Game.restore(g.save());
  assert.ok(restored);
  assert.equal(restored.buildingAt(20,8).id,b.id);
  assert.equal(restored.buildingAt(21,8),null);
  assert.deepEqual(restored.footprint('mill'),{w:2,h:2},
    'новые заказы имеют новый размер, старые постройки не меняются');
});
