'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const Nav=require('../navigation.js');
const {Game,id}=require('../engine.js');

test('A* обходит стену, не проходит сквозь непроходимые клетки',()=>{
  const walls=new Set(['2,0','2,1','2,2','2,3']);
  const free=(x,y)=>!walls.has(x+','+y);
  const path=Nav.route(6,5,{x:0,y:2},{x:5,y:2},free);
  assert.ok(path&&path.length>6);
  assert.deepEqual(path[0],{x:0,y:2});
  assert.deepEqual(path.at(-1),{x:5,y:2});
  for(let i=0;i<path.length;i++){
    assert.ok(free(path[i].x,path[i].y));
    if(i)assert.equal(Nav.distance(path[i],path[i-1]),1);
  }
  walls.add('2,4');
  assert.equal(Nav.route(6,5,{x:0,y:2},{x:5,y:2},free),null);
});

test('точки подхода находятся снаружи объекта, не внутри него',()=>{
  const building={x:3,y:2,size:{w:2,h:2}};
  const points=Nav.perimeter(building,8,7);
  assert.equal(points.length,8);
  assert.ok(points.every(p=>p.x<3||p.x>=5||p.y<2||p.y>=4));
  const free=(x,y)=>!(x>=3&&x<=4&&y>=2&&y<=3);
  const path=Nav.approach(8,7,{x:0,y:2},building,free);
  assert.ok(path);
  assert.ok(points.some(p=>p.x===path.at(-1).x&&p.y===path.at(-1).y));
  assert.deepEqual(Nav.nearest(8,7,{x:3,y:2},free),{x:2,y:2});
});

test('все четыре направления определяются по реальному смещению',()=>{
  assert.equal(Nav.facing({x:0,y:0},{x:1,y:0}),'se');
  assert.equal(Nav.facing({x:0,y:0},{x:0,y:1}),'sw');
  assert.equal(Nav.facing({x:0,y:0},{x:0,y:-1}),'ne');
  assert.equal(Nav.facing({x:0,y:0},{x:-1,y:0}),'nw');
  assert.equal(Nav.facing({x:1,y:2},{x:1,y:2},'nw'),'nw');
});

test('карта коллизий учитывает здания 2×2, лес, камни, поля и водоёмы',()=>{
  const g=new Game(1729,'settlement');
  assert.equal(g.walkable(10,8),false,'главное здание');
  assert.equal(g.walkable(11,9),false,'весь фундамент главного здания');
  assert.equal(g.walkable(22,14),false,'вода');
  assert.equal(g.walkable(16,9),false,'горная порода');
  assert.equal(g.walkable(11,7),false,'дерево');
  assert.equal(g.walkable(11,10),true,'площадка возле склада');
  assert.ok(g.approachCells(g.warehouse()).every(p=>g.walkable(p.x,p.y)));
  const farm=g.addBuilding('farm',13,9);
  assert.equal(g.placeField(13,8,'wheat').ok,true);
  assert.equal(g.walkable(13,9),false,'производственное здание');
  assert.equal(g.walkable(13,8),false,'поле с растительностью');
  assert.equal(g.walkable(-1,0),false);
  assert.ok(farm);
});

test('путь носильщиков остаётся дорожным и не пересекает здания',()=>{
  const g=new Game(1729,'settlement');
  const start=g.entrance(g.warehouse());
  const sawmill=g.addBuilding('sawmill',13,9);
  const route=g.route(start,g.entrance(sawmill));
  assert.ok(route?.length>=2);
  assert.ok(route.every(p=>g.roads[id(p.x,p.y)]&&!g.buildingAt(p.x,p.y)));
});

test('лесоруб обходит объекты и рубит только с соседней клетки',()=>{
  const g=new Game(1729,'settlement');
  const house=g.addBuilding('house',13,8);
  const b=g.addBuilding('logger',12,9);
  assert.equal(g.assignWorkers(b.id,1).ok,true);
  let worked=false,travelled=false;
  for(let k=0;k<550;k++){
    g.step(.1);
    const a=g.workAgents.find(a=>a.buildingId===b.id);
    if(!a)continue;
    const tile={x:Math.floor(a.x),y:Math.floor(a.y)};
    assert.equal(g.walkable(tile.x,tile.y),true,
      'рабочий прошёл через препятствие на шаге '+k);
    if(['out','arrive','return'].includes(a.phase))travelled=true;
    if(a.phase==='work'){
      worked=true;
      assert.ok(a.target,'рабочий нашёл дерево');
      assert.equal(Nav.distance(tile,a.target),1);
      assert.equal(a.facing,Nav.facing(a,Nav.centre(a.target)),
        'рабочий развернулся лицом к дереву');
    }
    if(worked&&a.phase==='return')break;
  }
  assert.ok(travelled,'реальная ходьба');
  assert.ok(worked,'лесоруб достиг доступной стороны дерева');
  assert.equal(g.walkable(house.x,house.y),false);
});

test('старый рабочий внутри склада переносится на свободный участок',()=>{
  const g=new Game(1729,'settlement'),b=g.addBuilding('logger',12,9);
  g.assignWorkers(b.id,1);
  g.workAgents=[{buildingId:b.id,x:10.5,y:8.5,phase:'arrive',
    target:null,progress:0,carrying:null}];
  g.step(.1);
  const a=g.workAgents[0];
  assert.ok(g.walkable(Math.floor(a.x),Math.floor(a.y)));
  assert.ok(['arrive','idle'].includes(a.phase));
});

test('путь и ориентация сохраняются и восстанавливаются детерминированно',()=>{
  const g=new Game(1729,'settlement'),b=g.addBuilding('logger',12,9);
  g.assignWorkers(b.id,1);
  for(let i=0;i<14;i++)g.step(.1);
  const restored=Game.restore(g.save());
  assert.ok(restored);
  assert.equal(restored.save(),g.save());
  for(let i=0;i<350;i++){g.step(.1);restored.step(.1);}
  assert.equal(restored.save(),g.save());
});
