'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const Art=require('../worker-art.js');

test('пять профессий имеют четыре направления и восемь разных кадров',()=>{
  assert.deepEqual(Art.roles,['porter','builder','logger','quarry','farmer']);
  assert.deepEqual(Art.DIRECTIONS,['se','sw','ne','nw']);
  assert.equal(Art.WIDTH,96);
  assert.equal(Art.HEIGHT,128);
  for(const role of Art.roles){
    for(const action of ['walk','work']){
      const svg=Art.atlas(role,action);
      assert.match(svg,/width="768" height="512"/);
      for(const direction of Art.DIRECTIONS){
        const frames=svg.match(new RegExp('data-direction="'+direction+'" data-frame="\\d"','g'))||[];
        assert.equal(frames.length,8,role+' '+action+' '+direction);
      }
      assert.equal((svg.match(/data-frame="/g)||[]).length,32);
      assert.match(svg,/linearGradient/);
      assert.ok(svg.length>15000,'у кадров есть независимая геометрия');
    }
  }
});
test('при переноске груза нет нарисованных заранее мешков',()=>{
  const cargo=Art.atlas('porter','carry');
  assert.equal((cargo.match(/data-frame="/g)||[]).length,32);
  assert.doesNotMatch(cargo,/sack|bag|груз|мешок/i);
  assert.notEqual(cargo,Art.atlas('porter','walk'));
});
test('рабочие движения отличаются от ходьбы, ошибки проверяются явно',()=>{
  for(const role of ['builder','logger','quarry','farmer']){
    assert.notEqual(Art.atlas(role,'walk'),Art.atlas(role,'work'),role);
  }
  assert.throws(()=>Art.atlas('unknown','walk'),/Неизвестная/);
  assert.throws(()=>Art.atlas('farmer','teleport'),/Неизвестная/);
});

test('свободные жители различаются и имеют самостоятельную анимацию ожидания',()=>{
  assert.deepEqual(Art.villagerRoles,[
    'villager-man-1','villager-man-2','villager-woman-1','villager-young-1'
  ]);
  assert.ok(Art.ACTIONS.includes('idle'));
  for(const role of [...Art.roles,...Art.villagerRoles]){
    const svg=Art.atlas(role,'idle');
    assert.match(svg,/width="768" height="512"/);
    for(const direction of Art.DIRECTIONS)
      assert.equal((svg.match(new RegExp('data-direction="'+direction+'" data-frame="\\d"','g'))||[]).length,8);
    assert.equal((svg.match(/data-frame="/g)||[]).length,32);
    assert.notEqual(svg,Art.atlas(role,'walk'));
  }
  const appearances=Art.villagerRoles.map(role=>Art.atlas(role,'idle'));
  assert.equal(new Set(appearances).size,4);
});
