'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const Frames=require('../profession-frames.js');
const Professions=require('../profession-actions.js');

test('все пять рабочих имеют по восемь отдельных кадров в четырёх направлениях',()=>{
  assert.equal(Frames.W,96);
  assert.equal(Frames.H,144);
  assert.equal(Frames.FRAMES,8);
  assert.deepEqual(Frames.DIRECTIONS,['se','sw','ne','nw']);
  assert.deepEqual(Object.keys(Frames.ACTIONS),['porter','builder','logger','quarry','farmer']);
  for(const [role,actions] of Object.entries(Frames.ACTIONS)){
    assert.ok(actions.includes('walk'),role);
    for(const action of actions){
      for(const direction of Frames.DIRECTIONS){
        const poses=Array.from({length:8},(_,f)=>Frames.pose(role,action,f,direction));
        assert.deepEqual(poses.map(p=>p.frame),[0,1,2,3,4,5,6,7]);
        assert.notDeepEqual(poses[0],poses[2],role+':'+action+':'+direction);
      }
    }
  }
});

test('рабочие действия совпадают с контрактами профессий',()=>{
  for(const role of Object.keys(Frames.ACTIONS)){
    const actions=Professions.actionsFor(role);
    for(const action of Frames.ACTIONS[role])
      assert.ok(actions.includes(action),role+':'+action);
  }
  assert.equal(Frames.ROLES.porter,0,
    'Тело носильщика не должно включать нарисованный заранее мешок');
  assert.equal(Frames.ROLES.builder,7);
});

test('руки и ноги отдельно меняют положение, направление сохраняется',()=>{
  for(const role of ['builder','logger','quarry','farmer']){
    const action=Frames.ACTIONS[role].find(a=>a!=='walk'&&!a.startsWith('carry'));
    const first=Frames.pose(role,action,0,'se');
    const second=Frames.pose(role,action,2,'se');
    assert.notEqual(first.rightArm,second.rightArm);
    assert.notEqual(first.tool,second.tool);
    assert.notEqual(first.torso,second.torso);
  }
  const walk=Frames.pose('porter','walk',2,'se');
  assert.notEqual(walk.leftLeg,walk.rightLeg);
  assert.notEqual(walk.leftArm,walk.rightArm);
  assert.equal(Frames.pose('logger','fell_tree',2,'sw').mirror,true);
  assert.equal(Frames.pose('logger','fell_tree',2,'nw').back,true);
  assert.throws(()=>Frames.pose('porter','fly',0,'se'),/Неизвестная/);
});

test('цельная фигура сохраняет ширину корпуса и две текстурные ноги',()=>{
  const calls=[],target={};
  for(const name of ['save','restore','translate','scale','rotate',
    'beginPath','rect','clip','drawImage','fillRect'])
    target[name]=(...args)=>calls.push([name,...args]);
  const img={naturalWidth:1056,naturalHeight:144};
  assert.equal(Frames.drawFrame(target,img,'logger','fell_tree',2,'se'),true);
  const sprites=calls.filter(c=>c[0]==='drawImage');
  assert.equal(sprites.length,4);
  assert.deepEqual(sprites[0].slice(2,6),[Frames.ROLES.logger*96,0,96,144],
    'Каждый кадр начинается с полной исходной фигуры');
  assert.equal(sprites[1][2],Frames.ROLES.logger*96);
  assert.equal(sprites[2][2],Frames.ROLES.logger*96);
  assert.deepEqual(sprites[3].slice(2,6),[Frames.ROLES.logger*96,0,96,111],
    'Корпус, голова и обе руки берутся из полной ширины оригинального рисунка');
  assert.ok(calls.filter(c=>c[0]==='rotate').length>=3);
  assert.ok(!calls.some(c=>c[0]==='ellipse'),
    'Нельзя подменять затылок огромным шаром');
  assert.equal(calls.at(-1)[0],'restore');
  const count=calls.length;
  assert.equal(Frames.drawFrame(target,null,'logger','fell_tree',2,'se'),false);
  assert.equal(calls.length,count);
});
