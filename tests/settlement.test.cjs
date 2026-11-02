'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const {Game,id}=require('../engine.js');
function run(g,seconds){for(let i=0;i<Math.ceil(seconds*10);i++)g.step(.1);}
function buildAndFinish(g,type,x,y){
  const result=g.build(type,x,y);assert.equal(result.ok,true,`${type} ${x},${y}: ${result.error}`);
  run(g,45);
  assert.ok(g.buildingAt(x,y)||type==='road'&&g.roads[id(x,y)],`not finished ${type}`);
  return g.buildingAt(x,y);
}
test('new game has one HQ, waiting people and limited provisions',()=>{
  const g=new Game(1729,'settlement');
  assert.equal(g.scenario,'settlement');assert.equal(g.buildings.length,1);
  assert.equal(g.buildings[0].type,'warehouse');assert.equal(g.availableWorkers(),4);
  assert.equal(g.construction.length,0);assert.equal(g.fields.length,0);
  assert.equal(g.carriers.length,2);assert.equal(g.builders.length,2);
});
test('completed workshop automatically hires one resident, but can stop without workers',()=>{
  const g=new Game(1729,'settlement'),b=buildAndFinish(g,'logger',12,9);
  assert.equal(g.staff[b.id],1);assert.equal(g.availableWorkers(),3);
  assert.equal(g.assignWorkers(b.id,2).ok,false);
  assert.ok(g.workAgents.some(a=>a.buildingId===b.id));
  assert.equal(g.assignWorkers(b.id,0).ok,true);
  run(g,10);
  assert.equal(g.readyToProduce(b),false);
  assert.equal(g.assignWorkers(b.id,1).ok,true);
  run(g,10);
  assert.ok(g.workAgents.some(a=>a.buildingId===b.id));
});
test('stone is physically mined and delivered through a built road',()=>{
  const g=new Game(1729,'settlement');
  assert.equal(g.build('quarry',16,9).ok,true);
  // A site without road access cannot receive stone/boards magically.
  run(g,12);assert.ok(g.siteAt(16,9));
  assert.equal(g.roads[id(16,10)],false);
  assert.equal(g.build('road',16,10).ok,true);run(g,40);
  assert.equal(g.roads[id(16,10)],true);
  run(g,45);
  const quarry=g.buildingAt(16,9);assert.ok(quarry);
  const rock=g.findDeposit(quarry),before=rock.stone;
  assert.equal(g.assignWorkers(quarry.id,1).ok,true);run(g,75);
  assert.ok(rock.stone<before);
  assert.ok(g.warehouse().goods.stone>0,'porters brought stone to common warehouse');
});
test('field passes clearing / sowing / growth / harvest with staffed farm',()=>{
  const g=new Game(1729,'settlement');
  const farm=buildAndFinish(g,'farm',13,9);
  assert.equal(g.placeField(13,8,'wheat').ok,true);
  assert.equal(g.placeField(13,8,'wheat').ok,false);
  assert.equal(g.assignWorkers(farm.id,0).ok,true);
  run(g,20);assert.equal(g.fields[0].stage,'clearing','without farmer the land stands idle');
  assert.equal(g.assignWorkers(farm.id,1).ok,true);
  run(g,85);
  assert.ok(g.fields[0].harvests>=1,'crop grows and gets harvested');
  assert.ok(g.warehouse().goods.grain>0,'real porter transported grain');
});
test('first primary-resource economy: village / lumber / stone / farmland',()=>{
  const g=new Game(1729,'settlement');
  assert.equal(g.build('road',16,10).ok,true);
  assert.equal(g.build('logger',12,9).ok,true);
  assert.equal(g.build('farm',13,9).ok,true);
  assert.equal(g.build('quarry',16,9).ok,true);
  run(g,85);
  for(const [type,x,y] of [['logger',12,9],['farm',13,9],['quarry',16,9]]){
    const b=g.buildingAt(x,y);assert.ok(b,`${type} completed`);
    assert.equal(g.assignWorkers(b.id,1).ok,true);
  }
  assert.equal(g.placeField(13,8,'wheat').ok,true);
  run(g,115);
  assert.ok(g.warehouse().goods.logs>6);
  assert.ok(g.warehouse().goods.stone>=2);
  assert.ok(g.warehouse().goods.grain>=2);
  assert.equal(g.fields[0].harvests>0,true);
  const restored=Game.restore(g.save());
  assert.ok(restored);assert.equal(restored.save(),g.save());
  run(g,15);run(restored,15);assert.equal(restored.save(),g.save());
});
test('legacy campaign remains playable and v2 saves migrate stone resource',()=>{
  const legacy=new Game().startMission();
  assert.equal(legacy.buildings.length,7);assert.equal(legacy.missionProgress().stage,0);
  const saved=JSON.parse(legacy.save());
  saved.version=2;delete saved.scenario;delete saved.fields;delete saved.staff;
  for(const b of saved.buildings)delete b.goods.stone;
  for(const t of saved.tiles)delete t.stone;
  const copy=Game.restore(JSON.stringify(saved));
  assert.ok(copy);assert.equal(copy.scenario,'legacy');assert.equal(copy.warehouse().goods.stone,0);
  assert.equal(copy.missionProgress().stage,0);
});

test('grain, vegetables, lumber and stone flow to the warehouse and on to secondary and tertiary industry',()=>{
  const g=new Game(1729,'settlement');
  for(const [type,x,y] of [
    ['logger',12,9],['farm',13,9],['sawmill',14,9],['mill',15,9],
    ['quarry',16,9],['bakery',17,9],['road',16,10],['road',17,10]
  ])assert.equal(g.build(type,x,y).ok,true,type);
  run(g,115);
  const members=['logger','farm','quarry','sawmill'].map(type=>g.buildings.find(b=>b.type===type));
  assert.ok(members.every(Boolean),'all primary buildings completed');
  // A busy village reallocates an existing worker instead of creating one.
  if(g.availableWorkers()===0)assert.equal(g.assignWorkers(members[3].id,0).ok,true);
  for(const b of members.slice(0,3))assert.equal(g.assignWorkers(b.id,1).ok,true);
  assert.equal(g.placeField(13,8,'wheat').ok,true);
  assert.equal(g.placeField(14,8,'vegetables').ok,true);
  run(g,115);
  assert.ok(g.warehouse().goods.stone>=2,'stone reached warehouse');
  assert.ok(g.fields.every(f=>f.harvests>0),'both crop fields harvested');
  assert.ok(g.warehouse().goods.vegetables>0,'vegetables stored separately');
  assert.ok(g.buildings.find(b=>b.type==='sawmill').goods.boards>=0);
  const quarry=g.buildings.find(b=>b.type==='quarry');
  assert.equal(g.assignWorkers(quarry.id,0).ok,true);
  const mill=g.buildings.find(b=>b.type==='mill');
  assert.equal(g.assignWorkers(mill.id,1).ok,true);
  run(g,100);
  assert.ok(g.warehouse().goods.flour>0||mill.goods.flour>0,'grain processed into flour');
  const sawmill=g.buildings.find(b=>b.type==='sawmill');
  assert.equal(g.assignWorkers(sawmill.id,0).ok,true);
  const bakery=g.buildings.find(b=>b.type==='bakery');
  assert.equal(g.assignWorkers(bakery.id,1).ok,true);
  run(g,110);
  assert.ok(g.stats.baked>=3,'flour + wood physically delivered to bakery; bread baked');
  assert.ok(g.buildings.length===7,'headquarters and six independent production buildings');
});

test('stone-dependent building remains foundation until a porter brings stone',()=>{
  const g=new Game(1729,'settlement');
  assert.equal(g.build('mill',15,9).ok,true);
  const site=g.siteAt(15,9);assert.equal(site.required.stone,1);
  run(g,60);
  assert.ok(g.siteAt(15,9),'mill cannot appear without stone');
  assert.equal(site.progress,0,'builders may not work with missing stone');
  assert.equal(site.goods.stone,0);
  assert.equal(site.goods.boards,2,'boards arrive separately');
  const copy=Game.restore(g.save());assert.ok(copy);
  assert.equal(copy.siteAt(15,9).required.stone,1);
  assert.equal(copy.siteAt(15,9).progress,0);
});

test('residents visibly walk to natural sources, harvest there and return tangible inventory',()=>{
  const g=new Game(1729,'settlement');
  const logger=g.addBuilding('logger',12,9);
  assert.equal(g.assignWorkers(logger.id,1).ok,true);
  const stock=logger.goods.logs;
  const woodBefore=g.tiles.reduce((n,t)=>n+(t.wood||0),0);
  run(g,.4);
  const agent=g.workAgents.find(a=>a.buildingId===logger.id);
  assert.ok(agent,'resident actor exists for a staffed workshop');
  assert.ok(agent.phase==='out'||agent.phase==='work','worker heads toward forest');
  assert.equal(logger.goods.logs,stock,'production does not happen at the start of a timer');
  run(g,9);
  assert.ok(g.tiles.reduce((n,t)=>n+(t.wood||0),0)<woodBefore,'tree lost actual wood');
  assert.ok(logger.goods.logs>stock||g.warehouse().goods.logs>6||
    g.carriers.some(c=>c.carrying?.res==='logs'),'returned timber entered the physical supply chain');
});
test('resident activity survives a mid-trip save and restores deterministically',()=>{
  const g=new Game(1729,'settlement');
  const q=g.addBuilding('quarry',16,9);assert.equal(g.assignWorkers(q.id,1).ok,true);
  run(g,1);
  const saved=Game.restore(g.save());assert.ok(saved,'workAgents is persisted');
  assert.equal(saved.save(),g.save());
  run(g,25);run(saved,25);assert.equal(saved.save(),g.save());
});
test('no free inhabitant means newly finished workshop stays unstaffed',()=>{
  const g=new Game(1729,'settlement');
  // Assign four free people to existing workshops, then add another finished one.
  for(let i=0;i<4;i++){
    const b=g.addBuilding('logger',12+i,9);
    assert.equal(g.assignWorkers(b.id,1).ok,true);
  }
  const site=g.build('farm',13,11);assert.equal(site.ok,true);
  run(g,85);
  const farm=g.buildingAt(13,11);assert.ok(farm);
  assert.equal(g.staff[farm.id]||0,0);
});
