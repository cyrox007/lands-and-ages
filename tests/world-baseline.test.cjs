'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const {Game,W,H}=require('../engine.js');

// Эталон до замены генератора: обновлять только с утверждённой миграцией мира.
function digest(value){
  let hash=2166136261;
  for(const char of value){
    hash^=char.charCodeAt(0);
    hash=Math.imul(hash,16777619)>>>0;
  }
  return hash.toString(16).padStart(8,'0');
}

function fingerprint(game){
  const terrain=game.tiles.map(t=>t.terrain[0]).join('|');
  const state=game.tiles.map(t=>[t.terrain,t.wood,t.stone,
    t.tree?.species||'-',t.tree?.age||0].join(':')).join('|');
  return {terrain:digest(terrain),state:digest(state)};
}

test('эталон карты 1729 сохраняется до перехода на новую модель',()=>{
  const g=new Game(1729,'settlement');
  assert.equal(W,26);
  assert.equal(H,18);
  assert.equal(g.tiles.length,468);
  const counts={};
  for(const cell of g.tiles)counts[cell.terrain]=(counts[cell.terrain]||0)+1;
  assert.deepEqual(counts,{grass:317,forest:121,water:16,hills:12,ruin:2});
  assert.deepEqual(fingerprint(g),{terrain:'836e05d8',state:'170215c9'});
  assert.equal(g.buildings.length,1);
  assert.deepEqual({x:g.warehouse().x,y:g.warehouse().y,size:g.warehouse().size},
    {x:10,y:8,size:{w:2,h:2}});
  assert.equal(g.roads.filter(Boolean).length,6);
});

test('текущая генерация повторяема и различает разные seed',()=>{
  const first=new Game(1729,'settlement');
  const second=new Game(1729,'settlement');
  const other=new Game(1730,'settlement');
  assert.equal(first.save(),second.save());
  assert.notDeepEqual(fingerprint(first),fingerprint(other));
  assert.deepEqual(fingerprint(other),{terrain:'0c479b25',state:'d5757af0'});
});

test('старая миссия и поселение используют одинаковую природную карту',()=>{
  const campaign=new Game(1729,'legacy');
  const settlement=new Game(1729,'settlement');
  assert.deepEqual(fingerprint(campaign),fingerprint(settlement));
  assert.equal(campaign.buildings.length,7);
  assert.equal(campaign.roads.filter(Boolean).length,16);
  assert.equal(settlement.buildings.length,1);
  assert.equal(settlement.roads.filter(Boolean).length,6);
});

test('эталон сохранений восстанавливается без изменения природного слоя',()=>{
  const game=new Game(1729,'settlement');
  const restored=Game.restore(game.save());
  assert.ok(restored);
  assert.equal(restored.save(),game.save());
  assert.deepEqual(fingerprint(restored),fingerprint(game));
});
