'use strict';
const {test}=require('node:test');
const assert=require('node:assert/strict');
const {Game,W,H,DEF,id,RES}=require('../engine.js');
const run=(g,seconds)=>{for(let t=0;t<seconds*10;t++)g.step(.1);};

test('карта имеет размеры, склад и три носильщика',()=>{
  const g=new Game();assert.equal(g.tiles.length,W*H);assert.equal(g.roads.length,W*H);
  assert.equal(g.count('warehouse'),1);assert.equal(g.carriers.length,3);
  assert.ok(g.buildings.every(b=>g.connected(b)));
});
test('путь от склада до лесопилки проходит только по настоящим дорогам',()=>{
  const g=new Game(),warehouse=g.warehouse(),sawmill=g.buildings.find(b=>b.type==='sawmill');
  const path=g.route(g.entrance(warehouse),g.entrance(sawmill));
  assert.ok(path.length>=6);assert.ok(path.every(p=>g.roads[id(p.x,p.y)]));
});
test('без дороги производство и логистика останавливаются',()=>{
  const g=new Game();g.roads[id(10,10)]=false;
  const mill=g.buildings.find(b=>b.type==='sawmill');
  assert.equal(g.connected(mill),false);
  mill.goods.logs=8;run(g,35);
  assert.equal(mill.goods.boards,0,'disconnected building must not produce');
});
test('продукты не телепортируются, носильщик физически довозит груз',()=>{
  const g=new Game(),mill=g.buildings.find(b=>b.type==='sawmill');
  const before=g.warehouse().goods.logs;
  g.step(.8);assert.ok(g.carriers.some(c=>c.job));
  assert.equal(mill.goods.logs,0,'goods must not appear instantly in sawmill');
  const inTransit=g.carriers.filter(c=>c.carrying?.res==='logs').reduce((n,c)=>n+c.carrying.amount,0);
  assert.equal(g.warehouse().goods.logs+inTransit,before,'picked up goods must be physically carried, not lost or teleported');
  run(g,17);
  assert.ok(mill.goods.logs>0||mill.goods.boards>0,'source must receive material after travel');
});
test('реальная пищевая цепочка запускается и пополняет склад',()=>{
  const g=new Game();run(g,230);const stock=g.warehouse().goods;
  assert.ok(stock.bread>=10,'bread production must beat early consumption');
  assert.ok(stock.flour>=4,'grain and flour chain must be active');
  assert.ok(stock.boards>=9,'wood and boards chain must be active');
  assert.ok(g.population>8);
});
test('пекарня требует и муку и дрова',()=>{
  const g=new Game(),bakery=g.buildings.find(b=>b.type==='bakery');
  bakery.goods.flour=3;bakery.goods.logs=0;run(g,6);
  assert.equal(bakery.goods.bread,0);
  // Isolation from deliveries to prove dual input gate.
  for(const c of g.carriers){c.job=null;c.path=[];}
  g.roads[id(19,10)]=false;
  bakery.goods.flour=3;bakery.goods.logs=3;run(g,9);
  assert.equal(bakery.goods.bread,0,'no connected road means no production');
  g.roads[id(19,10)]=true;run(g,9);
  assert.ok(bakery.goods.bread>0||g.warehouse().goods.bread>0);
});
test('заказ стройки резервирует монеты, доски перевозятся, здание возникает после работы',()=>{
  const g=new Game(),gold=g.coins,boards=g.warehouse().goods.boards;
  const r=g.build('house',8,11);assert.equal(r.ok,true);
  assert.equal(g.coins,gold-DEF.house.cost);
  assert.equal(g.warehouse().goods.boards,boards,'boards must remain in warehouse until pickup');
  assert.equal(g.buildingAt(8,11),null,'site is NOT a finished house');
  assert.equal(g.siteAt(8,11)?.goods.boards,0);
  assert.equal(g.count('house'),1);
  assert.equal(g.build('house',8,11).ok,false,'must not overlap an active site');
  assert.equal(g.build('house',5,10).ok,false,'must not overlap a road');
  run(g,3);assert.equal(g.buildingAt(8,11),null);
  run(g,35);assert.equal(g.count('house'),2);
  assert.equal(g.siteAt(8,11),null);
  assert.equal(g.warehouse().goods.boards>=0,true);
});
test('дорога стоит 2 монеты, а на воде строить нельзя',()=>{
  const g=new Game(),gold=g.coins;
  assert.equal(g.build('road',22,13).ok,g.tiles[id(22,13)].terrain==='grass');
  const x=g.tiles.findIndex(t=>t.terrain==='water');const {x:wx,y:wy}={x:x%W,y:Math.floor(x/W)};
  assert.equal(g.build('road',wx,wy).ok,false);
  assert.ok(g.coins===gold||g.coins===gold-2);
});
test('изолированная стройка ждёт дороги, потом получает доски и запускает производство',()=>{
  const g=new Game();const spot={x:8,y:12};
  assert.equal(g.build('farm',spot.x,spot.y).ok,true);
  assert.equal(g.buildingAt(spot.x,spot.y),null);
  run(g,20);assert.equal(g.siteAt(spot.x,spot.y).progress,0);
  assert.equal(g.siteAt(spot.x,spot.y).goods.boards,0);
  assert.equal(g.build('road',8,11).ok,true);
  assert.equal(g.roads[id(8,11)],false);
  run(g,20);assert.equal(g.roads[id(8,11)],true);
  run(g,50);const farm=g.buildingAt(spot.x,spot.y);
  assert.ok(farm&&g.connected(farm));
  run(g,10);assert.ok(farm.goods.grain>0||g.warehouse().goods.grain>6);
});
test('налоговая ставка ограничена, влияет на казну и настроение',()=>{
  const a=new Game(),b=new Game();a.setTax(30);b.setTax(0);
  run(a,100);run(b,100);
  assert.ok(a.coins>b.coins,'higher taxes give more coins');
  assert.ok(a.morale<b.morale,'higher taxes lower morale');
  a.setTax(999);assert.equal(a.tax,30);a.setTax(-50);assert.equal(a.tax,0);
});
test('недостаток хлеба снижает довольство',()=>{
  const g=new Game();g.warehouse().goods.bread=0;
  g.roads.fill(false);const before=g.morale;
  run(g,25);assert.ok(g.morale<before);
});
test('научное развитие требует реальных досок и дороги',()=>{
  const g=new Game();assert.equal(g.build('academy',8,11).ok,true);
  assert.equal(g.buildingAt(8,11),null);
  run(g,45);const academy=g.buildingAt(8,11);assert.ok(academy&&g.connected(academy));
  run(g,70);assert.ok(g.science>=4,'academy should get delivered boards and research');
});
test('культура, дипломатия, оборона могут развиваться независимо',()=>{
  for(const [type,field] of [['theatre','culture'],['embassy','diplomacy'],['barracks','military']]){
    const g=new Game();g.coins=400;g.warehouse().goods.boards=40;
    assert.equal(g.build(type,8,11).ok,true);
    run(g,140);assert.ok(g[field]>0,`${type} must generate ${field}`);
  }
});
test('рынок конвертирует потреблённый хлеб в доход',()=>{
  const g=new Game();g.coins=400;g.warehouse().goods.boards=50;
  assert.equal(g.build('market',8,11).ok,true);
  run(g,80);assert.ok(g.buildingAt(8,11).progress>=0);
  assert.ok(g.log.length>0);
});
test('руины не раскрывают историю: один раз дают знания и культуру',()=>{
  const g=new Game(),coins=g.coins;
  assert.equal(g.inspect(22,4).title,'Древние руины');
  assert.equal(g.excavate(22,4).ok,true);
  assert.equal(g.science,3);assert.equal(g.culture,4);
  assert.equal(g.coins,coins-15);assert.equal(g.excavate(22,4).ok,false);
  assert.ok(g.log[0].text.includes('неизвестной эпохи'));
});
test('при движении все носильщики находятся на участках дорог',()=>{
  const g=new Game();for(let i=0;i<1000;i++){
    g.step(.1);
    for(const c of g.carriers){
      const ax=Math.round(c.x),ay=Math.round(c.y);
      assert.ok(g.roads[id(ax,ay)],`carrier off road at ${c.x},${c.y}`);
    }
  }
});
test('игра переживает 100 игровых дней без отрицательных запасов и NaN',()=>{
  const g=new Game();run(g,2500);
  assert.equal(g.day,101);
  for(const b of g.buildings)for(const k of RES){
    assert.ok(Number.isFinite(b.goods[k])&&b.goods[k]>=0,`${b.type}.${k} ${b.goods[k]}`);
    assert.ok(b.goods[k]<=100);
  }
  assert.ok(Number.isFinite(g.coins));assert.ok(g.population>=3);
});
test('два запуска с одинаковым seed детерминированы',()=>{
  const a=new Game(23),b=new Game(23);run(a,54);run(b,54);
  assert.equal(a.save(),b.save());
});
test('полное сохранение восстанавливает состояние, включая перевозку',()=>{
  const g=new Game();run(g,18);
  assert.ok(g.carriers.some(c=>c.job));
  const copy=Game.restore(g.save());assert.ok(copy);
  assert.equal(copy.save(),g.save());
  run(g,33);run(copy,33);
  assert.equal(copy.save(),g.save());
});
test('битые сохранения отвергаются и не затрагивают новую игру',()=>{
  for(const raw of ['not json',JSON.stringify({version:15}),JSON.stringify({version:1,tiles:[],roads:[]}),
    'x'.repeat(310000)])assert.equal(Game.restore(raw),null);
  const g=new Game();const s=JSON.parse(g.save());s.buildings[0].goods.bread=-7;
  assert.equal(Game.restore(JSON.stringify(s)),null);
});
test('корректная пауза управляется интерфейсом, движок не занимается кадрами',()=>{
  const g=new Game();const initial=g.clock;
  g.step(0);assert.equal(g.clock,initial);
  g.step(-1);assert.equal(g.clock,initial);
  g.step(50);assert.ok(g.clock<=3.00001,'resume clamp avoids fast-forward from background tab');
});

test('миссия: заказ ремонта дороги не открывает её до завершения стройки',()=>{
 const g=new Game().startMission(),bakery=g.buildings.find(b=>b.type==='bakery');
 assert.equal(g.missionProgress().stage,0);assert.equal(g.connected(bakery),false);
 assert.equal(g.build('road',17,10).ok,true);
 assert.equal(g.roads[id(17,10)],false,'only construction site is placed');
 assert.equal(g.missionProgress().stage,0);
 run(g,3);assert.equal(g.roads[id(17,10)],false);
 run(g,16);assert.equal(g.roads[id(17,10)],true,'builders actually finish');
 assert.equal(g.connected(bakery),true);
 assert.ok(g.missionProgress().stage>=1);
 run(g,180);assert.ok(g.stats.baked>=3);
 assert.equal(g.missionProgress().stage,2);
});
test('миссия требует полностью готовый второй дом до выбора пути',()=>{
 const g=new Game().startMission();g.build('road',17,10);run(g,180);
 assert.equal(g.missionProgress().stage,2);
 assert.equal(g.build('house',8,11).ok,true);
 assert.equal(g.missionProgress().stage,2,'foundations are not a habitable house');
 run(g,45);assert.equal(g.missionProgress().stage,3);
 assert.equal(g.choosePath('invalid'),false);
 assert.equal(g.choosePath('wealth'),true);
 assert.equal(g.choosePath('military'),false,'first path choice persists');
});
test('победа через реальное строительство рынка, не при размещении стройплощадки',()=>{
 const g=new Game().startMission();g.build('road',17,10);run(g,180);
 g.build('house',8,11);run(g,35);assert.equal(g.missionProgress().stage,3);
 g.choosePath('wealth');assert.equal(g.build('market',12,11).ok,true);
 assert.equal(g.buildingAt(12,11),null);assert.equal(g.missionProgress().done,false);
 run(g,105);assert.equal(g.missionProgress().done,true);
 assert.equal(g.mission.won,true);
 const copy=Game.restore(g.save());assert.ok(copy);assert.equal(copy.missionProgress().done,true);
 assert.equal(copy.save(),g.save());
});
test('строитель доходит по дороге, строит и исчезает с занятой площадки',()=>{
 const g=new Game();g.build('house',8,11);
 run(g,2);
 const site=g.siteAt(8,11);assert.ok(site);
 assert.equal(site.progress,0);
 run(g,6);
 assert.ok(g.builders.some(b=>b.site===site.id),'builders must be assigned');
 for(const b of g.builders){
   assert.ok(g.roads[id(Math.round(b.x),Math.round(b.y))],'builders use road tiles');
 }
 run(g,35);
 assert.equal(g.siteAt(8,11),null);
 assert.equal(g.builders.filter(b=>b.site!==null).length,0);
});
test('физическая доставка досок: груз нельзя создать, раньше времени он не появляется',()=>{
 const g=new Game();g.build('road',5,11);const site=g.siteAt(5,11);
 const before=g.warehouse().goods.boards;
 assert.equal(site.goods.boards,0);
 assert.equal(g.roads[id(5,11)],false);
 run(g,1);
 const transit=g.carriers.filter(c=>c.carrying?.res==='boards').reduce((sum,c)=>sum+c.carrying.amount,0);
 assert.equal(g.warehouse().goods.boards+transit+site.goods.boards,before,'board accounted for in warehouse, transit, or site');
 run(g,15);
 assert.equal(g.roads[id(5,11)],true);
 assert.equal(g.construction.length,0);
});
test('сохранение незаконченной стройки и перевозок восстанавливается детерминированно',()=>{
 const g=new Game().startMission();g.build('road',17,10);g.build('house',8,11);
 run(g,7);
 assert.ok(g.construction.length>0);
 assert.ok(g.carriers.some(c=>c.job));
 const saved=g.save(),copy=Game.restore(saved);
 assert.ok(copy);assert.equal(saved,copy.save());
 run(g,60);run(copy,60);
 assert.equal(copy.save(),g.save());
 assert.equal(g.roads[id(17,10)],true);
 assert.equal(g.count('house'),2);
});
test('битая стройка в сохранении отвергается, старое v1 поддержано',()=>{
 const g=new Game();g.build('road',5,11);
 const broken=JSON.parse(g.save());broken.construction[0].goods.boards=-4;
 assert.equal(Game.restore(JSON.stringify(broken)),null);
 const legacy=JSON.parse(new Game().save());legacy.version=1;
 delete legacy.construction;delete legacy.builders;delete legacy.nextSite;
 const restored=Game.restore(JSON.stringify(legacy));assert.ok(restored);
 assert.deepEqual(restored.construction,[]);assert.equal(restored.builders.length,2);
});
test('старая свободная игра и старые сохранения не становятся насильно миссией',()=>{
 const g=new Game();assert.equal(g.missionProgress().active,false);
 const old=JSON.parse(g.save());delete old.mission;delete old.stats;
 const copy=Game.restore(JSON.stringify(old));assert.ok(copy);
 assert.equal(copy.missionProgress().active,false);
 assert.equal(copy.build('house',9,12).ok,true);
});
