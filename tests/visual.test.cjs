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