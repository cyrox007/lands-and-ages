'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const A=require('../profession-actions.js');
const Motion=require('../painted-motion.js');

test('пакеты охватывают все существующие профессии поселения',()=>{
  assert.deepEqual(A.roles,[
    'porter','builder','logger','quarry','farmer','sawmill','mill',
    'bakery','academy','theatre','market','embassy','barracks'
  ]);
  assert.equal(A.roles.filter(role=>A.PACKS[role].agent).length,5);
  for(const role of A.roles){
    const actions=A.actionsFor(role);
    assert.ok(actions.includes('idle'),role);
    assert.ok(actions.length>=2,role);
    assert.ok(A.artRole(role),role);
    assert.deepEqual(A.resolve(role),{id:'idle',state:'idle'});
  }
});

test('особые действия запускаются только в соответствующих фазах',()=>{
  assert.deepEqual(A.resolve('logger',{phase:'work'}),{id:'fell_tree',state:'work'});
  assert.deepEqual(A.resolve('quarry',{phase:'work'}),{id:'mine_stone',state:'work'});
  assert.deepEqual(A.resolve('farmer',{phase:'work'}),{id:'harvest_crop',state:'work'});
  assert.deepEqual(A.resolve('logger',{phase:'return',carrying:{res:'logs'}}),
    {id:'carry_logs',state:'carry'});
  assert.deepEqual(A.resolve('quarry',{phase:'return',carrying:{res:'stone'}}),
    {id:'carry_stone',state:'carry'});
  assert.deepEqual(A.resolve('farmer',{phase:'return',carrying:{res:'grain'}}),
    {id:'carry_crop',state:'carry'});
  assert.deepEqual(A.resolve('farmer',{phase:'out'}),{id:'walk',state:'walk'});
  assert.deepEqual(A.resolve('farmer',{phase:'idle'}),{id:'idle',state:'idle'});
});

test('строитель отражает реальную стадию строительства',()=>{
  assert.deepEqual(A.resolve('builder',{phase:'work',progress:0.1}),
    {id:'lay_foundation',state:'work'});
  assert.deepEqual(A.resolve('builder',{phase:'work',progress:0.5}),
    {id:'assemble_frame',state:'work'});
  assert.deepEqual(A.resolve('builder',{phase:'work',progress:0.9}),
    {id:'finish_roof',state:'work'});
  assert.deepEqual(A.resolve('builder',{phase:'travel'}),{id:'walk',state:'walk'});
  assert.deepEqual(A.resolve('builder',{phase:'idle'}),{id:'idle',state:'idle'});
});

test('носильщик не получает постоянный нарисованный мешок',()=>{
  assert.equal(A.artRole('porter'),'villager-man-1');
  assert.deepEqual(A.resolve('porter',{job:{phase:'pickup'}}),
    {id:'walk',state:'walk'});
  assert.deepEqual(A.resolve('porter',{job:{phase:'deliver'},carrying:{res:'boards'}}),
    {id:'carry',state:'carry'});
  assert.deepEqual(A.resolve('porter'),{id:'idle',state:'idle'});
  assert.deepEqual(A.resolve('porter',{cue:'pickup'}),{id:'pickup',state:'work'});
  assert.deepEqual(A.resolve('porter',{cue:'unload'}),{id:'unload',state:'work'});
});

test('работники мастерских работают только при готовом производстве',()=>{
  for(const [role,id] of [
    ['sawmill','saw_boards'],['mill','grind_grain'],
    ['bakery','knead_dough'],['academy','study_book'],
    ['theatre','perform_scene'],['market','trade_goods'],
    ['embassy','write_letter'],['barracks','drill_guard']
  ]){
    assert.deepEqual(A.resolve(role,{active:true}),{id,state:'work'},role);
    assert.deepEqual(A.resolve(role,{active:false}),{id:'idle',state:'idle'},role);
  }
  assert.deepEqual(A.resolve('unknown',{active:true}),{id:'idle',state:'idle'});
});

test('недоступные пока действия не маскируются под готовую механику',()=>{
  assert.deepEqual(A.pendingFor('farmer'),['clear_field','sow_seed','tend_crop']);
  assert.ok(A.pendingFor('logger').includes('plant_tree'));
  assert.ok(A.pendingFor('porter').length===0);
  assert.ok(!A.actionsFor('farmer').includes('sow_seed'));
});

test('динамика рубки, добычи и уборки различается',()=>{
  const logger=Motion.pose('work',2,'se',0,'fell_tree');
  const quarry=Motion.pose('work',2,'se',0,'mine_stone');
  const farmer=Motion.pose('work',2,'se',0,'harvest_crop');
  assert.ok(Math.abs(logger.upper)>Math.abs(quarry.upper));
  assert.ok(Math.abs(quarry.upper)>Math.abs(farmer.upper));
  assert.notEqual(logger.lean,farmer.lean);
});
