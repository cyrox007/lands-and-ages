const {test}=require('node:test');
const assert=require('node:assert/strict');
const V=require('../visual-model.js');
const W=5,H=5;
function layout(cells){const r=Array(W*H).fill(false);for(const [x,y] of cells)r[y*W+x]=true;return r;}
test('автоматические дорожные соединения: концы и прямые',()=>{
 const r=layout([[1,2],[2,2],[3,2]]);
 assert.equal(V.roadMask(r,1,2,W,H),V.E);
 assert.equal(V.roadMask(r,2,2,W,H),V.E|V.W);
 assert.equal(V.roadKind(V.roadMask(r,2,2,W,H)),'straight');
 assert.equal(V.roadKind(V.roadMask(r,1,2,W,H)),'end');
});
test('повороты, T-узел и перекрёстки корректно различаются',()=>{
 let r=layout([[1,2],[2,2],[2,3]]);
 assert.equal(V.roadMask(r,2,2,W,H),V.W|V.S);
 assert.equal(V.roadKind(V.roadMask(r,2,2,W,H)),'corner');
 r=layout([[1,2],[2,2],[3,2],[2,3]]);
 assert.equal(V.roadKind(V.roadMask(r,2,2,W,H)),'junction');
 r=layout([[1,2],[2,2],[3,2],[2,3],[2,1]]);
 assert.equal(V.roadKind(V.roadMask(r,2,2,W,H)),'crossroads');
});
test('строящаяся дорога не считается действующим соединением',()=>{
 const r=layout([[1,2],[3,2]]);
 assert.equal(V.roadMask(r,1,2,W,H),0);
 assert.equal(V.roadMask(r,2,2,W,H),0);
});
test('визуальные стадии соответствуют физически доставленным доскам и работе',()=>{
 const s={required:{boards:2},goods:{boards:0},progress:10,duration:10};
 assert.equal(V.constructionStage(s),'foundation');
 s.goods.boards=2;s.progress=1;assert.equal(V.constructionStage(s),'foundation');
 s.progress=3;assert.equal(V.constructionStage(s),'frame');
 s.progress=6;assert.equal(V.constructionStage(s),'walls');
 s.progress=9;assert.equal(V.constructionStage(s),'roof');
});
test('направление ходьбы выводится из реального маршрута, а не из таймера',()=>{
 const b={x:4.5,y:4,path:[{x:4,y:4},{x:5,y:4}],segment:0};
 assert.deepEqual(V.facing(b),{direction:'se',moving:true});
 b.path=[{x:4,y:4},{x:4,y:3}];b.x=4;b.y=3.8;
 assert.deepEqual(V.facing(b),{direction:'ne',moving:true});
 b.path=[];assert.deepEqual(V.facing(b),{direction:'se',moving:false});
});

test('циклы рабочих: 8 разных кадров для ходьбы и работы',()=>{
 const w=Array.from({length:8},(_,i)=>V.animationFrame('walk',i/11,0));
 const b=Array.from({length:8},(_,i)=>V.animationFrame('work',i/9,0));
 assert.deepEqual(w,[0,1,2,3,4,5,6,7]);
 assert.deepEqual(b,[0,1,2,3,4,5,6,7]);
});
test('рабочие стоят без анимации в idle и при паузе',()=>{
 assert.equal(V.animationFrame('idle',0,2),0);
 assert.equal(V.animationFrame('idle',1000,2),0);
 assert.equal(V.animationFrame('walk',1.7,1),V.animationFrame('walk',1.7,1));
 assert.equal(V.animationFrame('work',1.7,1),V.animationFrame('work',1.7,1));
});
test('анимационные циклы детерминированы по игровому времени, не по Date.now()',()=>{
 const t=3.14;
 assert.equal(V.animationFrame('walk',t,1),V.animationFrame('walk',t,1));
 assert.equal(V.animationFrame('walk',t+8/11,1),V.animationFrame('walk',t,1));
 assert.equal(V.animationFrame('work',t+8/9,2),V.animationFrame('work',t,2));
});

test('кадры шага зависят от расстояния, не от времени и FPS',()=>{
  const V=require('../visual-model.js');
  assert.equal(V.gaitFrame(0),0);
  assert.equal(V.gaitFrame(.34),4);
  assert.equal(V.gaitFrame(.68),0);
  assert.equal(V.gaitFrame(.17),2);
  assert.equal(V.gaitFrame(.17),V.gaitFrame(.17)); // paused/no position delta
  assert.equal(V.gaitFrame(NaN),0);
  assert.equal(V.gaitFrame(-2),0);
});

test('производственная анимация не запускается при простое или без ресурсов',()=>{
  const V=require('../visual-model.js');
  const b={type:'bakery',progress:2};
  assert.equal(V.productionActive(b,true,true),true);
  assert.equal(V.productionActive(b,true,false),false);
  assert.equal(V.productionActive(b,false,true),false);
  assert.equal(V.productionActive({...b,progress:0},true,true),false);
  assert.equal(V.productionActive({type:'house',progress:2},true,true),false);
  for(const type of ['logger','sawmill','farm','mill','bakery'])
    assert.equal(V.productionActive({type,progress:.1},true,true),true,type);
});
test('носильщик отображает ровно фактический груз без постоянного мешка',()=>{
  assert.deepEqual(V.porterAppearance(null),{bodySheet:'worker-porter-walk',cargo:null});
  const resources=['logs','boards','stone','grain','vegetables','flour','bread'];
  for(const res of resources){
    const appearance=V.porterAppearance({res,amount:2});
    assert.equal(appearance.bodySheet,'worker-porter-walk',res);
    assert.equal(appearance.cargo,res,'рисуется только актуальный ресурс');
  }
});

test('брусчатка покрывает все 16 топологий дорог без пропусков',()=>{
  for(let mask=0;mask<16;mask++){
    const plan=V.cobblestonePlan(mask);
    const directions=[V.N,V.E,V.S,V.W].filter(bit=>mask&bit);
    assert.deepEqual(plan.arms.map(arm=>arm.bit),directions);
    assert.equal(plan.center.length,9,'центр тоже мощёный');
    assert.equal(plan.arms.reduce((n,arm)=>n+arm.stones.length,0),15*directions.length);
    for(const arm of plan.arms){
      assert.equal(arm.stones[0].u0,.14);
      assert.ok(Math.abs(arm.stones.at(-1).u1-.5)<1e-10,
        'соседние дорожные плитки сходятся на границе участков');
      for(const stone of arm.stones){
        assert.ok(stone.u0>=.14 && stone.u1<=.501);
        assert.ok(stone.v0>=-.221 && stone.v1<=.221);
        assert.ok(stone.u1>stone.u0 && stone.v1>stone.v0);
      }
    }
  }
});
test('повороты, T-узлы и крестовые перекрёстки имеют собственные мощёные рукава',()=>{
  for(const [mask,expected] of [
    [V.N|V.E,2],[V.N|V.S,2],[V.N|V.E|V.S,3],
    [V.N|V.E|V.S|V.W,4]
  ]){
    const p=V.cobblestonePlan(mask);
    assert.equal(p.arms.length,expected);
    assert.ok(p.arms.every(a=>a.stones.length===15));
  }
});
