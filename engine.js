/* Стратегия 0.4 — roads and buildings need physical deliveries and real builders. */
(function(root,factory){
  const api=factory();
  if(typeof module==='object'&&module.exports)module.exports=api;
  if(root)root.StrategyEngine=api;
})(typeof globalThis==='object'?globalThis:this,function(){
  'use strict';
  const W=26,H=18;
  const RES=['logs','boards','stone','grain','vegetables','flour','bread'];
  const RES_NAME={logs:'Брёвна',boards:'Доски',stone:'Камень',grain:'Зерно',vegetables:'Овощи',flour:'Мука',bread:'Хлеб'};
  const DEF={
    warehouse:{name:'Склад',symbol:'▣',cost:0,boards:0,max:100,recipe:null},
    logger:{name:'Лесничество',symbol:'♣',cost:27,boards:1,max:12,workers:1,recipe:{out:{logs:2},time:4}},
    quarry:{name:'Каменоломня',symbol:'◆',cost:36,boards:2,max:12,workers:1,recipe:{out:{stone:2},time:6}},
    sawmill:{name:'Лесопилка',symbol:'▥',cost:38,boards:2,max:12,workers:1,recipe:{in:{logs:2},out:{boards:1},time:6}},
    farm:{name:'Ферма',symbol:'✿',cost:32,boards:1,max:12,workers:1,recipe:{out:{grain:2},time:5}},
    mill:{name:'Мельница',symbol:'✳',cost:42,boards:2,stone:1,max:12,workers:1,recipe:{in:{grain:2},out:{flour:1},time:6}},
    bakery:{name:'Пекарня',symbol:'♨',cost:45,boards:2,stone:2,max:12,workers:1,recipe:{in:{flour:1,logs:1},out:{bread:3},time:7}},
    house:{name:'Дом',symbol:'⌂',cost:25,boards:2,stone:1,max:0,recipe:null},
    academy:{name:'Академия',symbol:'✧',cost:75,boards:4,max:8,workers:1,recipe:{in:{boards:1},point:'science',gain:4,time:9}},
    theatre:{name:'Театр',symbol:'♫',cost:60,boards:3,max:8,workers:1,recipe:{in:{bread:1},point:'culture',gain:3,time:9}},
    market:{name:'Рынок',symbol:'⚖',cost:50,boards:2,max:8,workers:1,recipe:{in:{bread:2},point:'wealth',gain:9,time:8}},
    embassy:{name:'Посольство',symbol:'◆',cost:80,boards:4,max:8,workers:1,recipe:{in:{bread:1,boards:1},point:'diplomacy',gain:3,time:10}},
    barracks:{name:'Казармы',symbol:'⚑',cost:65,boards:3,max:8,workers:1,recipe:{in:{bread:1,boards:1},point:'military',gain:3,time:10}}
  };
  const COLORS={warehouse:'#ffc671',quarry:'#a8a2a0',logger:'#5eae79',sawmill:'#c79057',farm:'#8bbb61',mill:'#e4b76c',bakery:'#e49c65',house:'#96b4dc',academy:'#9f9ee8',theatre:'#e6a7ce',market:'#e8bc76',embassy:'#a1c8e6',barracks:'#df9593'};
  const inside=(x,y)=>x>=0&&x<W&&y>=0&&y<H;
  const id=(x,y)=>y*W+x;
  const xy=i=>({x:i%W,y:Math.floor(i/W)});
  const adj=(x,y)=>[[x+1,y],[x-1,y],[x,y+1],[x,y-1]].filter(p=>inside(...p));
  const dict=()=>Object.fromEntries(RES.map(r=>[r,0]));
  const distance=(a,b)=>Math.abs(a.x-b.x)+Math.abs(a.y-b.y);
  function makeRng(seed){return function(){seed=(Math.imul(seed,1664525)+1013904223)>>>0;return seed/4294967296;};}
  class Game {
    constructor(seed=1729,scenario='legacy'){
      this.version=3;this.scenario=scenario;this.fields=[];this.staff={};this.workAgents=[];this.seed=seed|0;this.w=W;this.h=H;this.randomSeed=seed>>>0;
      this.tiles=[];this.roads=[];this.buildings=[];this.construction=[];this.carriers=[];this.builders=[];this.nextBuilding=1;this.nextSite=1;
      this.coins=175;this.population=8;this.morale=73;this.tax=14;this.day=1;
      this.science=0;this.culture=0;this.diplomacy=0;this.military=0;
      this.stats={baked:0,developed:{wealth:0,science:0,culture:0,diplomacy:0,military:0}};
      this.mission={active:false,chosen:null,won:false};
      this.clock=0;this.dayClock=0;this.dispatchClock=0;this.log=[];this.excavated=[];
      this.generate();
      if(scenario==='settlement')this.initializeSettlement();else this.initialize();
      this.note(scenario==='settlement'?'Поселение основано. Назначьте жителей, постройте первые производства и поля.':'Поселение основано. Дороги связывают мастерские и склад.');
    }
    generate(){
      const rng=makeRng(this.seed);
      for(let y=0;y<H;y++)for(let x=0;x<W;x++){
        const r=rng(),edge=(x<2||y<2||x>=W-2||y>=H-2);
        let terrain=r<.12?'forest':r<.16?'hills':r<.185?'water':'grass';
        if(edge&&r<.55)terrain='forest';
        if(y>=7&&y<=12&&x>=3&&x<=20)terrain='grass';
        if(y===6&&x>=6&&x<=9)terrain='forest';
        if(y===7&&(x===11||x===12))terrain='forest';
        if(x===16&&y===9)terrain='hills';
        if(x===21&&y>=3&&y<=6)terrain='hills';
        if((x===22&&y===4)||(x===2&&y===14))terrain='ruin';
        this.tiles.push({terrain,wood:terrain==='forest'?40:0,stone:terrain==='hills'?55:0});
        this.roads.push(false);
      }
    }
    initialize(){
      for(let x=4;x<=19;x++)this.roads[id(x,10)]=true;
      for(const [type,x,y,goods] of [
        ['warehouse',4,9,{logs:7,boards:9,grain:6,flour:2,bread:8}],
        ['logger',7,9,{}],['sawmill',10,9,{}],['farm',13,9,{}],
        ['mill',16,9,{}],['bakery',19,9,{}],['house',6,11,{}]
      ])this.addBuilding(type,x,y,goods);
      for(let i=0;i<3;i++)this.carriers.push({id:i+1,x:4,y:10,segment:0,path:[],job:null,carrying:null});
      for(let i=0;i<2;i++)this.builders.push({id:i+1,x:4,y:10,segment:0,path:[],site:null,phase:'idle'});
    }
    initializeSettlement(){
      // A genuine new game: one headquarters, no pre-built industry.
      this.coins=420;this.population=8;this.morale=78;
      const store=this.addBuilding('warehouse',11,9,{boards:18,logs:6,bread:32});
      for(let x=10;x<=15;x++)this.roads[id(x,10)]=true;
      for(let i=0;i<2;i++)this.carriers.push({id:i+1,x:11,y:10,segment:0,path:[],job:null,carrying:null});
      for(let i=0;i<2;i++)this.builders.push({id:i+1,x:11,y:10,segment:0,path:[],site:null,phase:'idle'});
      this.mission={active:false,chosen:null,won:false};
    }
    employed(){return Object.values(this.staff).reduce((sum,n)=>sum+n,0);}
    availableWorkers(){return Math.max(0,this.population-this.employed()-this.carriers.length-this.builders.length);}
    assignWorkers(buildingId,count){
      if(this.scenario!=='settlement')return {ok:false,error:'Назначения доступны в новом поселении'};
      const b=this.buildings.find(b=>b.id===buildingId);
      if(!b||!DEF[b.type].recipe)return {ok:false,error:'Здесь нет рабочих мест'};
      const previous=this.staff[b.id]||0,cap=DEF[b.type].workers||1;
      if(!Number.isInteger(count)||count<0||count>cap)return {ok:false,error:'Превышено число рабочих мест'};
      if(count-previous>this.availableWorkers())return {ok:false,error:'Нет свободных жителей'};
      this.staff[b.id]=count;this.note(DEF[b.type].name+': занято '+count+'/'+cap+' рабочих мест.');
      return {ok:true};
    }
    fieldAt(x,y){return this.fields.find(f=>f.x===x&&f.y===y)||null;}
    nearbyFarm(x,y){return this.buildings.find(b=>b.type==='farm'&&distance(b,{x,y})<=3)||null;}
    placeField(x,y,crop='wheat'){
      if(this.scenario!=='settlement')return {ok:false,error:'Поля доступны в новой игре'};
      if(!inside(x,y)||this.tiles[id(x,y)].terrain!=='grass'||this.roads[id(x,y)]||
        this.buildingAt(x,y)||this.siteAt(x,y)||this.fieldAt(x,y))return {ok:false,error:'Нужен свободный луг'};
      if(!['wheat','barley','vegetables'].includes(crop))return {ok:false,error:'Неизвестная культура'};
      if(!this.nearbyFarm(x,y))return {ok:false,error:'Поле должно быть рядом с фермой (до 3 клеток)'};
      if(this.coins<4)return {ok:false,error:'Для подготовки поля нужно 4 монеты'};
      this.coins-=4;const field={x,y,crop,stage:'clearing',progress:0,harvests:0};
      this.fields.push(field);this.note('Заложено поле: '+crop+'. Земледельцы начнут подготовку почвы.');
      return {ok:true,field};
    }
    fieldFarm(field){return this.nearbyFarm(field.x,field.y);}
    advanceFields(dt){
      if(this.scenario!=='settlement')return;
      for(const f of this.fields){
        const farm=this.fieldFarm(f);
        if(!farm||(this.staff[farm.id]||0)<1||!this.connected(farm)||f.stage==='ripe')continue;
        f.progress+=dt;
        const durations={clearing:4,sown:3,growing:f.crop==='vegetables'?18:f.crop==='barley'?12:15};
        if(f.progress>=durations[f.stage]){
          f.progress-=durations[f.stage];
          f.stage=f.stage==='clearing'?'sown':f.stage==='sown'?'growing':'ripe';
        }
      }
    }
    startMission(){
      // The food chain starts broken. The player must act to restore it.
      this.roads[id(17,10)]=false;
      this.mission={active:true,chosen:null,won:false};
      this.stats={baked:0,developed:{wealth:0,science:0,culture:0,diplomacy:0,military:0}};
      this.note('Испытание долины: восстановите дорогу у мельницы и пекарни.');
      return this;
    }
    choosePath(path){
      if(!this.mission?.active||!['wealth','science','culture','diplomacy','military'].includes(path))return false;
      if(this.mission.chosen&&this.mission.chosen!==path)return false;
      this.mission.chosen=path;
      this.note('Совет поселения утвердил новый путь развития.');
      return true;
    }
    missionProgress(){
      if(!this.mission?.active)return {active:false,stage:-1,done:false};
      if(this.mission.won)return {active:true,stage:4,done:true,target:null,progress:1};
      if(!this.roads[id(17,10)]){const site=this.siteAt(17,10);return {active:true,stage:0,done:false,target:{x:17,y:10},progress:site?site.progress/site.duration:0,site:site?.id||null};}
      if(this.stats.baked<3)return {active:true,stage:1,done:false,target:{x:19,y:9},progress:this.stats.baked/3};
      if(this.count('house')<2){const site=this.construction.find(s=>s.type==='house');return {active:true,stage:2,done:false,target:{x:8,y:11},progress:site?site.progress/site.duration:0};}
      if(!this.mission.chosen)return {active:true,stage:3,done:false,target:null,progress:0};
      const key=this.mission.chosen;
      if(this.stats.developed[key]<3){const required={wealth:'market',science:'academy',culture:'theatre',diplomacy:'embassy',military:'barracks'}[key];const site=this.construction.find(s=>s.type===required);return {active:true,stage:3,done:false,target:{x:12,y:11},progress:site?Math.min(.8,site.progress/site.duration*.8):Math.min(1,this.stats.developed[key]/3),chosen:key};}
      this.mission.won=true;
      this.note('Победа! Долина восстановлена и определила путь развития.');
      return {active:true,stage:4,done:true,target:null,progress:1,chosen:key};
    }
    note(message){this.log.unshift({day:this.day,text:message});this.log.length=Math.min(this.log.length,35);}
    buildingAt(x,y){return this.buildings.find(b=>b.x===x&&b.y===y)||null;}
    siteAt(x,y){return this.construction.find(s=>s.x===x&&s.y===y)||null;}
    siteById(siteId){return this.construction.find(s=>s.id===siteId)||null;}
    siteMaterials(site){return site.required.boards||0;}
    siteStage(site){
      const have=site.goods.boards||0,need=this.siteMaterials(site);
      if(Object.entries(site.required).some(([k,n])=>(site.goods[k]||0)<n))return this.entrance(site)?'Доставка материалов':'Нет подъезда к стройке';
      const workers=this.builders.filter(b=>b.site===site.id&&b.phase==='work').length;
      return workers?'Работают строители':'Ожидание строителей';
    }
    addBuilding(type,x,y,goods={}){
      const b={id:this.nextBuilding++,type,x,y,goods:{...dict(),...goods},progress:0};
      this.buildings.push(b);return b;
    }
    warehouse(){return this.buildings.find(b=>b.type==='warehouse');}
    entrance(building){
      if(!building)return null;
      const opts=adj(building.x,building.y).filter(([x,y])=>this.roads[id(x,y)]);
      // A broken road may leave two opposite entrances: a construction site
      // must use the warehouse-reachable side, never the disconnected side.
      if(building.id<0){const home=this.buildings.find(b=>b.type==='warehouse');
        const start=home&&this.entrance(home);
        const accessible=opts.find(([x,y])=>start&&this.route(start,{x,y}));
        return accessible?{x:accessible[0],y:accessible[1]}:null;
      }
      return opts.length?{x:opts[0][0],y:opts[0][1]}:null;
    }
    route(from,to){
      if(!from||!to)return null;
      const start=id(from.x,from.y),goal=id(to.x,to.y);
      if(!this.roads[start]||!this.roads[goal])return null;
      const seen=new Int32Array(W*H).fill(-1),q=[start];seen[start]=start;
      for(let i=0;i<q.length;i++){
        const v=q[i];if(v===goal)break;
        const {x,y}=xy(v);
        for(const [nx,ny] of adj(x,y)){
          const n=id(nx,ny);if(seen[n]!==-1||!this.roads[n])continue;
          seen[n]=v;q.push(n);
        }
      }
      if(seen[goal]<0)return null;
      const path=[];for(let p=goal;p!==start;p=seen[p])path.push(xy(p));
      path.push(xy(start));return path.reverse();
    }
    connected(building){return Boolean(this.route(this.entrance(this.warehouse()),this.entrance(building)));}
    canBuild(type,x,y){
      if(!inside(x,y))return {ok:false,error:'За пределами карты'};
      if(type==='field'){
        if(this.scenario!=='settlement')return {ok:false,error:'Поля недоступны'};
        if(!inside(x,y)||this.tiles[id(x,y)].terrain!=='grass'||this.roads[id(x,y)]||
          this.buildingAt(x,y)||this.siteAt(x,y)||this.fieldAt(x,y))return {ok:false,error:'Нужен свободный луг'};
        if(!this.nearbyFarm(x,y))return {ok:false,error:'Нужна ферма рядом'};
        return this.coins>=4?{ok:true}:{ok:false,error:'Не хватает монет'};
      }
      if(type==='road'){
        if(this.roads[id(x,y)])return {ok:false,error:'Дорога уже проложена'};
        if(this.buildingAt(x,y)||this.siteAt(x,y)||this.fieldAt(x,y))return {ok:false,error:'Клетка уже занята'};
        if(this.tiles[id(x,y)].terrain!=='grass')return {ok:false,error:'Здесь нельзя проложить дорогу'};
        if(this.coins<2)return {ok:false,error:'Недостаточно монет'};
        if(this.uncommittedBoards()<1)return {ok:false,error:'Не хватает досок на дорожную стройку'};
        return {ok:true};
      }
      if(!DEF[type]||type==='warehouse')return {ok:false,error:'Недоступное сооружение'};
      if(this.buildingAt(x,y)||this.siteAt(x,y)||this.fieldAt(x,y)||this.roads[id(x,y)])return {ok:false,error:'Клетка занята'};
      if(this.tiles[id(x,y)].terrain!=='grass'&&!(type==='quarry'&&this.tiles[id(x,y)].terrain==='hills'))return {ok:false,error:'Неподходящий участок для этого здания'};
      if(type==='quarry'&&!this.findDeposit({x,y}))return {ok:false,error:'Каменоломне нужно месторождение рядом'};
      const w=this.warehouse();
      if(this.coins<DEF[type].cost)return {ok:false,error:'Не хватает монет'};
      if(this.uncommittedBoards()<DEF[type].boards)return {ok:false,error:'Не хватает свободных досок на складе'};
      return {ok:true};
    }
    uncommittedBoards(){
      // Orders reserve boards without removing them from the warehouse:
      // boards only physically leave storage when a carrier picks them up.
      const outstanding=this.construction.reduce((n,s)=>n+Math.max(0,(s.required.boards||0)-s.goods.boards-this.reservedTo(s.id,'boards')),0);
      return Math.max(0,this.warehouse().goods.boards-outstanding);
    }
    build(type,x,y){
      if(type==='field')return this.placeField(x,y);
      const check=this.canBuild(type,x,y);if(!check.ok)return check;
      const isRoad=type==='road',price=isRoad?2:DEF[type].cost;
      const boards=isRoad?1:DEF[type].boards;
      const stone=this.scenario==='settlement'&&!isRoad?(DEF[type].stone||0):0;
      this.coins-=price; // Coin cost is paid on order, not the construction time.
      const site={id:-(this.nextSite++),type,x,y,goods:dict(),required:{boards,stone},
        progress:0,duration:isRoad?3.5:Math.max(8,10+DEF[type].boards*2.5),price};
      this.construction.push(site);
      this.note((isRoad?'Участок дороги':DEF[type].name)+': заложена стройка. Материалы: доски '+boards+(stone?', камень '+stone:'')+'; нужны строители.');
      return {ok:true,site};
    }
    finishSite(site){
      const i=this.construction.indexOf(site);if(i<0)return;
      this.construction.splice(i,1);
      if(site.type==='road'){this.roads[id(site.x,site.y)]=true;this.note('Дорога завершена и открыта для движения.');}
      else {const b=this.addBuilding(site.type,site.x,site.y);
        // A completed workshop hires one waiting villager automatically.
        if(this.scenario==='settlement'&&DEF[b.type].recipe){
          if(this.availableWorkers()>0){
            this.staff[b.id]=1;
            this.note(DEF[b.type].name+': назначен один свободный житель.');
          }else this.note(DEF[b.type].name+': пока нет свободного работника.');
        }
        this.note(DEF[b.type].name+': строительство завершено. '+(this.connected(b)?'Предприятие подключено.':'Для работы нужна дорога.'));}
      for(const worker of this.builders)if(worker.site===site.id){worker.site=null;worker.phase='idle';worker.path=[];worker.segment=0;}
    }
    dispatchBuilders(){
      for(const worker of this.builders){
        if(worker.site!==null)continue;
        const source={x:Math.round(worker.x),y:Math.round(worker.y)};
        for(const site of this.construction){
          if(Object.entries(site.required).some(([k,n])=>(site.goods[k]||0)<n))continue;
          const entrance=this.entrance(site),path=entrance&&this.route(source,entrance);
          if(!path)continue;
          worker.site=site.id;worker.path=path;worker.segment=0;
          worker.phase=path.length===1?'work':'travel';break;
        }
      }
    }
    moveBuilder(b,dt){
      if(b.site===null||b.phase!=='travel')return;
      if(!this.siteById(b.site)){b.site=null;b.phase='idle';b.path=[];return;}
      let remaining=dt*1.6;
      while(remaining>0&&b.segment<b.path.length-1){
        const target=b.path[b.segment+1],dx=target.x-b.x,dy=target.y-b.y,d=Math.hypot(dx,dy);
        if(d<.0001){b.x=target.x;b.y=target.y;b.segment++;continue;}
        if(d<=remaining){b.x=target.x;b.y=target.y;b.segment++;remaining-=d;}
        else {b.x+=dx*remaining/d;b.y+=dy*remaining/d;remaining=0;}
      }
      if(b.segment===b.path.length-1)b.phase='work';
    }
    advanceConstruction(dt){
      this.dispatchBuilders();
      for(const worker of this.builders)this.moveBuilder(worker,dt);
      for(const site of this.construction.slice()){
        if(Object.entries(site.required).some(([k,n])=>(site.goods[k]||0)<n))continue;
        // A worker on site makes real, time-consuming progress. Two work faster.
        const count=this.builders.filter(w=>w.site===site.id&&w.phase==='work').length;
        if(!count)continue;
        site.progress=Math.min(site.duration,site.progress+dt*count);
        if(site.progress>=site.duration-1e-7)this.finishSite(site);
      }
    }
    inspect(x,y){
      if(!inside(x,y))return {title:'Вне карты',desc:''};
      const b=this.buildingAt(x,y);
      if(b){
        const def=DEF[b.type],goods=RES.filter(k=>b.goods[k]>0).map(k=>RES_NAME[k]+': '+b.goods[k]).join(' · ');
        const agent=this.workAgents.find(a=>a.buildingId===b.id);
        const activity={arrive:'Работник идёт из поселения к предприятию.',out:'Работник направляется к природному ресурсу.',
          work:'Работник добывает или собирает ресурс.',return:'Работник несёт добычу на предприятие.',
          idle:'Работник ожидает нового задания.'};
        const needsStaff=this.scenario==='settlement'&&def.recipe;
        const state=needsStaff?((this.staff[b.id]||0)<1?'Нет назначенных работников. ':
          agent?activity[agent.phase]+' ':this.readyToProduce(b)?'Идёт производство. ':'Ожидание сырья или урожая. '):'';
        return {title:def.name,desc:state+(this.connected(b)?'Соединено с дорожной сетью. ':'Нет маршрута до склада. ')+(goods||'Запасов нет.')};
      }
      const site=this.siteAt(x,y);
      if(site){const have=site.goods.boards||0;return {title:'Стройка: '+(site.type==='road'?'дорога':DEF[site.type].name),
        desc:this.siteStage(site)+'. Доски: '+have+'/'+this.siteMaterials(site)+'. Камень: '+(site.goods.stone||0)+'/'+(site.required.stone||0)+'. Работа: '+Math.floor(site.progress/site.duration*100)+'%. Материалы идут по дороге, строители работают после доставки.'};}
      const field=this.fieldAt(x,y);
      if(field)return {title:'Поле: '+({wheat:'Пшеница',barley:'Ячмень',vegetables:'Овощи'}[field.crop]),desc:'Стадия: '+field.stage+'. Урожаев собрано: '+field.harvests+'. Полевые работы ведут назначенные фермеры.'};
      if(this.roads[id(x,y)])return {title:'Дорога',desc:'По ней носильщики перемещают реальные грузы между зданиями.'};
      const t=this.tiles[id(x,y)];
      if(t.terrain==='ruin')return {title:'Древние руины',desc:this.excavated.includes(id(x,y))?'Экспедиция завершила описание находок.':'Среди разрушенных камней виден неизвестный знак. Исследуйте находку.'};
      if(t.terrain==='forest')return {title:'Лесной массив',desc:'Запас древесины: '+t.wood+'. Лесничества используют ближайшие участки.'};
      if(t.terrain==='hills')return {title:'Каменное месторождение',desc:'Камня осталось: '+(t.stone||0)};
      const name={grass:'Луг',hills:'Холмы',water:'Водоём'};
      return {title:name[t.terrain],desc:'Местность мира; некоторые участки ограничивают застройку.'};
    }
    excavate(x,y){
      const where=id(x,y);if(!inside(x,y)||this.tiles[where].terrain!=='ruin')return {ok:false,error:'Здесь нет руин'};
      if(this.excavated.includes(where))return {ok:false,error:'Находка уже изучена'};
      if(this.coins<15)return {ok:false,error:'Для экспедиции нужно 15 монет'};
      this.coins-=15;this.science+=3;this.culture+=4;this.excavated.push(where);
      this.note('Экспедиция вернулась с каменной печатью неизвестной эпохи. Учёные спорят о её значении.');
      return {ok:true};
    }
    setTax(value){if(!Number.isFinite(value))return;this.tax=Math.max(0,Math.min(30,Math.round(value)));}
    count(type){return this.buildings.filter(b=>b.type===type).length;}
    findForest(b){
      let best=null,dist=Infinity;
      for(let y=Math.max(0,b.y-3);y<=Math.min(H-1,b.y+3);y++)for(let x=Math.max(0,b.x-3);x<=Math.min(W-1,b.x+3);x++){
        const t=this.tiles[id(x,y)],d=distance({x,y},b);if(t.terrain==='forest'&&t.wood>0&&d<dist){best=t;dist=d;}
      }
      return best;
    }
    findDeposit(b){
      let best=null,dist=Infinity;
      for(let y=Math.max(0,b.y-3);y<=Math.min(H-1,b.y+3);y++)for(let x=Math.max(0,b.x-3);x<=Math.min(W-1,b.x+3);x++){
        const t=this.tiles[id(x,y)],d=distance({x,y},b);
        if(t.terrain==='hills'&&(t.stone||0)>0&&d<dist){best=t;dist=d;}
      }
      return best;
    }
    readyToProduce(b){
      const def=DEF[b.type],r=def?.recipe;if(!r||!this.connected(b))return false;
      if(this.scenario==='settlement'&&(this.staff[b.id]||0)<(def.workers||1))return false;
      if(b.type==='quarry'&&!this.findDeposit(b))return false;
      if(b.type==='farm'&&this.scenario==='settlement'){
        const field=this.fields.find(f=>f.stage==='ripe'&&distance(f,b)<=3&&
          b.goods[f.crop==='vegetables'?'vegetables':'grain']+(f.crop==='barley'?3:2)<=def.max);
        if(!field)return false;
      }
      if(b.type==='logger'&&!this.findForest(b))return false;
      if(r.in&&Object.entries(r.in).some(([k,n])=>b.goods[k]<n))return false;
      if(r.out&&!(b.type==='farm'&&this.scenario==='settlement')&&Object.entries(r.out).some(([k,n])=>b.goods[k]+n>def.max))return false;
      return true;
    }
    produce(b,dt){
      const r=DEF[b.type].recipe;
      if(!r)return;
      if(this.scenario==='settlement'&&['logger','quarry','farm'].includes(b.type))return;
      if(!this.readyToProduce(b)){b.progress=0;return;}
      b.progress+=dt;
      if(b.progress<r.time)return;
      b.progress-=r.time;
      if(!this.readyToProduce(b))return;
      let outputs=r.out||{};
      if(b.type==='farm'&&this.scenario==='settlement'){
        const field=this.fields.find(f=>f.stage==='ripe'&&distance(f,b)<=3&&
          b.goods[f.crop==='vegetables'?'vegetables':'grain']+(f.crop==='barley'?3:2)<=DEF[b.type].max);
        if(!field)return;
        outputs=field.crop==='vegetables'?{vegetables:2}:{grain:field.crop==='barley'?3:2};
        field.stage='sown';field.progress=0;field.harvests++;
      }
      for(const [k,n] of Object.entries(r.in||{}))b.goods[k]-=n;
      for(const [k,n] of Object.entries(outputs))b.goods[k]+=n;
      if(b.type==='bakery')this.stats.baked+=r.out.bread;
      if(r.point)this.stats.developed[r.point]=(this.stats.developed[r.point]||0)+r.gain;
      if(b.type==='logger'){const forest=this.findForest(b);if(forest)forest.wood=Math.max(0,forest.wood-2);}
      if(b.type==='quarry'){const rock=this.findDeposit(b);if(rock)rock.stone=Math.max(0,rock.stone-2);}
      if(r.point){if(r.point==='wealth')this.coins+=r.gain;else this[r.point]+=r.gain;}
    }
    // Reservations exclude cargo/jobs already allocated to a carrier.
    resourceCell(b,type){
      let best=null,dist=Infinity;
      for(let y=Math.max(0,b.y-3);y<=Math.min(H-1,b.y+3);y++)
        for(let x=Math.max(0,b.x-3);x<=Math.min(W-1,b.x+3);x++){
          const tile=this.tiles[id(x,y)],d=distance({x,y},b);
          if(((type==='logger'&&tile.terrain==='forest'&&tile.wood>=2)||
              (type==='quarry'&&tile.terrain==='hills'&&tile.stone>=2)||
              (type==='farm'&&this.fields.some(f=>f.x===x&&f.y===y&&f.stage==='ripe'))) &&
             d<dist){best={x,y};dist=d;}
        }
      return best;
    }
    // Separate resident task from carrier logistics: residents walk from
    // their workshop to the natural source, work, and return with a real load.
    // Only arrival at the workshop deposits newly extracted resources.
    advanceWorkAgents(dt){
      if(this.scenario!=='settlement')return;
      const primary=new Set(['logger','quarry','farm']);
      this.workAgents=this.workAgents.filter(a=>{
        const b=this.buildings.find(v=>v.id===a.buildingId);
        return Boolean(b&&primary.has(b.type)&&((this.staff[b.id]||0)>0||a.carrying));
      });
      for(const b of this.buildings){
        if(!primary.has(b.type)||(this.staff[b.id]||0)<1)continue;
        if(!this.workAgents.some(a=>a.buildingId===b.id))
          this.workAgents.push({buildingId:b.id,x:this.warehouse().x+.5,
            y:this.warehouse().y+.5,phase:'arrive',target:null,progress:0,carrying:null});
      }
      for(const a of this.workAgents){
        const b=this.buildings.find(v=>v.id===a.buildingId);
        if(!b)continue;
        if(a.phase==='idle'){
          a.x=b.x+.5;a.y=b.y+.5;b.progress=0;
          if(!this.readyToProduce(b))continue;
          const cell=this.resourceCell(b,b.type);
          if(!cell)continue;
          a.target=cell;a.phase='out';a.progress=0;
        }
        if(a.phase==='out'||a.phase==='return'||a.phase==='arrive'){
          const destination=a.phase==='return'||a.phase==='arrive'?
            {x:b.x+.5,y:b.y+.5}:{x:a.target.x+.5,y:a.target.y+.5};
          const dx=destination.x-a.x,dy=destination.y-a.y,d=Math.hypot(dx,dy),travel=dt*1.65;
          if(d>travel){a.x+=dx/d*travel;a.y+=dy/d*travel;}
          else {
            a.x=destination.x;a.y=destination.y;
            if(a.phase==='out'){a.phase='work';a.progress=0;}
            else {
              if(a.carrying)b.goods[a.carrying.res]+=a.carrying.amount;
              a.carrying=null;a.phase='idle';b.progress=0;
            }
          }
        }else if(a.phase==='work'){
          if((this.staff[b.id]||0)<1){a.phase='return';continue;}
          a.progress+=dt;b.progress=a.progress;
          const duration=b.type==='quarry'?2.3:b.type==='farm'?2:2.6;
          if(a.progress<duration)continue;
          const cell=a.target,tile=this.tiles[id(cell.x,cell.y)];
          if(b.type==='logger'&&tile.wood>=2){
            tile.wood-=2;a.carrying={res:'logs',amount:2};
          }else if(b.type==='quarry'&&tile.stone>=2){
            tile.stone-=2;a.carrying={res:'stone',amount:2};
          }else if(b.type==='farm'){
            const field=this.fieldAt(cell.x,cell.y);
            if(field&&field.stage==='ripe'){
              a.carrying=field.crop==='vegetables'?{res:'vegetables',amount:2}:
                {res:'grain',amount:field.crop==='barley'?3:2};
              field.stage='sown';field.progress=0;field.harvests++;
            }
          }
          a.phase='return';a.progress=0;b.progress=0;
        }
      }
    }
    reservedFrom(bId,k){return this.carriers.reduce((sum,c)=>sum+(c.job?.source===bId&&c.job.res===k&&!c.carrying?c.job.amount:0),0);}
    reservedTo(bId,k){return this.carriers.reduce((sum,c)=>sum+(c.job?.target===bId&&c.job.res===k?c.job.amount:0),0);}
    available(b,k){return Math.max(0,b.goods[k]-this.reservedFrom(b.id,k));}
    sourceFor(target,k){
      const targetEntrance=this.entrance(target);if(!targetEntrance)return null;
      return this.buildings
        .filter(b=>(this.scenario!=='settlement'||target.type==='warehouse'||b.type==='warehouse')&&b.id!==target.id&&this.available(b,k)>0&&this.entrance(b)&&this.route(this.entrance(b),targetEntrance))
        .sort((a,b)=>distance(a,target)-distance(b,target)||a.id-b.id)[0]||null;
    }
    chooseDelivery(){
      // Construction is top priority, but not magical: every board travels on
      // a real carrier along the road to an entrance adjacent to the site.
      for(const site of this.construction){
        if(!this.entrance(site))continue;
        for(const [resource,required] of Object.entries(site.required)){
          const need=required-(site.goods[resource]||0)-this.reservedTo(site.id,resource);
          if(need<=0)continue;
          const source=this.sourceFor(site,resource);if(!source)continue;
          const amount=Math.min(3,need,this.available(source,resource));
          if(amount>0)return {source,target:site,res:resource,amount};
        }
      }
      // In settlement mode output moves through the headquarters first.
      // Every unit changes ownership at pickup and again at delivery.
      if(this.scenario==='settlement'){
        const store=this.warehouse();
        for(const b of this.buildings){
          if(b.type==='warehouse'||!this.connected(b))continue;
          const outputs=DEF[b.type].recipe?.out||{};
          for(const k of b.type==='farm'?['grain','vegetables']:Object.keys(outputs)){
            const available=this.available(b,k);
            if(available<2||store.goods[k]+this.reservedTo(store.id,k)>=100)continue;
            const amount=Math.min(3,available,100-store.goods[k]-this.reservedTo(store.id,k));
            if(amount>0)return {source:b,target:store,res:k,amount};
          }
        }
      }
      // Priority: feed real production inputs before storing manufactured goods.
      for(const b of this.buildings){
        if(!this.connected(b))continue;
        const inputs=DEF[b.type].recipe?.in||{};
        for(const [k,n] of Object.entries(inputs)){
          if(b.goods[k]+this.reservedTo(b.id,k)>=Math.max(4,n*2))continue;
          const source=this.sourceFor(b,k);if(!source)continue;
          const amount=Math.min(3,this.available(source,k),DEF[b.type].max-b.goods[k]-this.reservedTo(b.id,k));
          if(amount>0)return {source,target:b,res:k,amount};
        }
      }
      const store=this.warehouse();
      for(const b of this.buildings){
        if(b.type==='warehouse'||!this.connected(b))continue;
        const outputs=DEF[b.type].recipe?.out||{};
        for(const k of Object.keys(outputs)){
          const available=this.available(b,k);
          if(available<3||store.goods[k]+this.reservedTo(store.id,k)>=100)continue;
          return {source:b,target:store,res:k,amount:Math.min(3,available,100-store.goods[k]-this.reservedTo(store.id,k))};
        }
      }
      return null;
    }
    dispatch(){
      for(const carrier of this.carriers){
        if(carrier.job)continue;
        const choice=this.chooseDelivery();if(!choice)continue;
        const start={x:Math.round(carrier.x),y:Math.round(carrier.y)};
        const pickup=this.entrance(choice.source),delivery=this.entrance(choice.target);
        const toSource=this.route(start,pickup),toTarget=this.route(pickup,delivery);
        if(!toSource||!toTarget)continue;
        carrier.job={source:choice.source.id,target:choice.target.id,res:choice.res,amount:choice.amount,phase:'pickup',toTarget};
        carrier.path=toSource;carrier.segment=0;
      }
    }
    moveCarrier(c,dt){
      if(!c.job)return;
      let remaining=dt*2.4;
      // The path contains road cells only; interpolate between successive tiles.
      while(remaining>0&&c.job){
        if(c.segment>=c.path.length-1){
          this.arrive(c);continue;
        }
        const next=c.path[c.segment+1];
        const dx=next.x-c.x,dy=next.y-c.y,d=Math.hypot(dx,dy);
        if(d<.0001){c.x=next.x;c.y=next.y;c.segment++;continue;}
        if(remaining>=d){c.x=next.x;c.y=next.y;c.segment++;remaining-=d;}
        else{c.x+=dx*remaining/d;c.y+=dy*remaining/d;remaining=0;}
      }
    }
    arrive(c){
      const job=c.job;
      if(job.phase==='pickup'){
        const source=this.buildings.find(b=>b.id===job.source);
        const available=Math.min(source?.goods[job.res]||0,job.amount);
        if(!available){c.job=null;c.path=[];return;}
        source.goods[job.res]-=available;
        c.carrying={res:job.res,amount:available};job.amount=available;job.phase='deliver';
        c.path=job.toTarget;c.segment=0;
      }else{
        const target=this.buildings.find(b=>b.id===job.target)||this.siteById(job.target);
        if(target&&c.carrying)target.goods[c.carrying.res]+=c.carrying.amount;
        c.carrying=null;c.job=null;c.path=[];c.segment=0;
      }
    }
    advanceDay(){
      this.day++;
      const stock=this.warehouse().goods;
      const need=Math.ceil(this.population/5);
      const breadEaten=Math.min(need,stock.bread);stock.bread-=breadEaten;
      const vegetableEaten=this.scenario==='settlement'?Math.min(need-breadEaten,stock.vegetables):0;
      stock.vegetables-=vegetableEaten;
      const eaten=breadEaten+vegetableEaten;
      if(eaten<need){this.morale=Math.max(0,this.morale-9);this.note('Не хватает хлеба. Население недовольно.');}
      else this.morale=Math.min(100,this.morale+(this.tax>23?-3:this.tax<10?3:1));
      this.coins+=Math.floor(this.population*this.tax/18);
      if(this.scenario==='settlement'&&this.day%8===0){
        for(const tile of this.tiles)if(tile.terrain==='forest')tile.wood=Math.min(40,(tile.wood||0)+1);
      }
      this.morale=Math.max(0,Math.min(100,this.morale-(this.tax>23?3:0)));
      const capacity=8+this.count('house')*6;
      if(eaten===need&&this.morale>=55&&this.population<capacity&&this.day%3===0)this.population++;
      if(this.morale<20&&this.day%2===0&&this.population>3)this.population--;
      if(this.scenario==='settlement'){
        // A shrinking village cannot employ more people than it has.
        this.population=Math.max(this.carriers.length+this.builders.length,this.population);
        let surplus=this.employed()+this.carriers.length+this.builders.length-this.population;
        if(surplus>0)for(const b of this.buildings.slice().reverse()){
          if(surplus<=0)break;
          const n=Math.min(this.staff[b.id]||0,surplus);
          if(n){this.staff[b.id]-=n;surplus-=n;this.note(DEF[b.type].name+': часть работников освободила места из-за сокращения населения.');}
        }
      }
      if(this.day%4===0)this.note('День '+this.day+': '+this.population+' жителей · настроение '+this.morale+'%.');
    }
    step(dt){
      if(!Number.isFinite(dt)||dt<=0)return;
      // Bounded, fixed sub-steps to keep simulation deterministic after tab resume.
      let remain=Math.min(dt,3);
      while(remain>0){
        const sub=Math.min(.1,remain);remain-=sub;
        this.clock+=sub;this.dayClock+=sub;this.dispatchClock+=sub;
        this.advanceFields(sub);
        this.advanceWorkAgents(sub);
        for(const b of this.buildings)this.produce(b,sub);
        for(const c of this.carriers)this.moveCarrier(c,sub);
        this.advanceConstruction(sub);
        if(this.dispatchClock>=.65){this.dispatchClock-=.65;this.dispatch();}
        if(this.dayClock>=25){this.dayClock-=25;this.advanceDay();}
      }
    }
    hud(){
      const w=this.warehouse();return {day:this.day,coins:this.coins,population:this.population,morale:this.morale,
        tax:this.tax,science:this.science,culture:this.culture,diplomacy:this.diplomacy,military:this.military,
        goods:{...w.goods},carriers:this.carriers.map(c=>({x:c.x,y:c.y,res:c.carrying?.res||null})),
        connected:this.buildings.filter(b=>this.connected(b)).length,total:this.buildings.length,
        scenario:this.scenario,freeWorkers:this.availableWorkers(),staff:{...this.staff},workAgents:this.workAgents.map(a=>({...a})),fields:this.fields.map(f=>({...f})),
        sites:this.construction.map(s=>({id:s.id,type:s.type,x:s.x,y:s.y,delivered:s.goods.boards,boards:s.required.boards,deliveredStone:s.goods.stone||0,stone:s.required.stone||0,progress:s.progress,duration:s.duration,state:this.siteStage(s)}))};
    }
    save(){return JSON.stringify({version:3,scenario:this.scenario,staff:this.staff,workAgents:this.workAgents,fields:this.fields,seed:this.seed,tiles:this.tiles,roads:this.roads,buildings:this.buildings,
      construction:this.construction,builders:this.builders,nextSite:this.nextSite,
      carriers:this.carriers,nextBuilding:this.nextBuilding,coins:this.coins,population:this.population,morale:this.morale,
      tax:this.tax,day:this.day,science:this.science,culture:this.culture,diplomacy:this.diplomacy,
      military:this.military,mission:this.mission,stats:this.stats,clock:this.clock,dayClock:this.dayClock,dispatchClock:this.dispatchClock,log:this.log,
      excavated:this.excavated});}
    static restore(raw){
      try{
        if(typeof raw!=='string'||raw.length>300000)return null;
        const s=JSON.parse(raw);
        // v1/v2 persisted before stone was introduced; migrate on load.
        if(s&&[1,2].includes(s.version)&&Array.isArray(s.buildings)&&Array.isArray(s.tiles)){
          for(const b of s.buildings)if(b.goods){if(b.goods.stone===undefined)b.goods.stone=0;if(b.goods.vegetables===undefined)b.goods.vegetables=0;}
          for(const c of s.construction||[])if(c.goods){if(c.goods.stone===undefined)c.goods.stone=0;if(c.goods.vegetables===undefined)c.goods.vegetables=0;}
          for(const t of s.tiles)if(t.stone===undefined)t.stone=t.terrain==='hills'?55:0;
        }
        if(![1,2,3].includes(s.version)||!Array.isArray(s.tiles)||s.tiles.length!==W*H||
          !Array.isArray(s.roads)||s.roads.length!==W*H||!Array.isArray(s.buildings)||
          !s.buildings.length||s.buildings.length>W*H||!Array.isArray(s.carriers)||(s.version===3?(s.carriers.length<1||s.carriers.length>6):s.carriers.length!==3)||
          !s.buildings.some(b=>b.type==='warehouse')||!Number.isFinite(s.coins)||
          !Number.isInteger(s.day)||s.day<1||!Number.isFinite(s.population)||
          !s.buildings.every(b=>DEF[b.type]&&inside(b.x,b.y)&&b.goods&&RES.every(k=>Number.isFinite(b.goods[k])&&b.goods[k]>=0)))return null;
        const game=new Game(s.seed,s.scenario==='settlement'?'settlement':'legacy');
        const fields=['scenario','staff','fields','workAgents','tiles','roads','buildings','construction','builders','nextSite','carriers','nextBuilding','coins','population','morale','tax','day',
          'science','culture','diplomacy','military','mission','stats','clock','dayClock','dispatchClock','log','excavated'];
        for(const f of fields)if(Object.prototype.hasOwnProperty.call(s,f))game[f]=s[f];
        // Existing v0.1 / 0.2 saves did not have a mission; preserve free play.
        if(!game.mission||typeof game.mission!=='object')game.mission={active:false,chosen:null,won:false};
        if(!game.stats||typeof game.stats!=='object')game.stats={baked:0,developed:{wealth:0,science:0,culture:0,diplomacy:0,military:0}};
        if(!game.stats.developed||typeof game.stats.baked!=='number'||!Number.isFinite(game.stats.baked))return null;
        if(!game.carriers.every(c=>Number.isFinite(c.x)&&Number.isFinite(c.y)&&Array.isArray(c.path)&&c.path.length<500))return null;
        // Older saves did not have construction, so remain fully compatible.
        if(s.version>=2&&(!Array.isArray(s.construction)||!Array.isArray(s.builders)||
          !Number.isInteger(s.nextSite)||s.nextSite<1||s.construction.length>W*H||(s.version===3?(s.builders.length<1||s.builders.length>6):s.builders.length!==2)||
          !s.construction.every(c=>Number.isInteger(c.id)&&c.id<0&&inside(c.x,c.y)&&
            (c.type==='road'||(DEF[c.type]&&c.type!=='warehouse'))&&c.goods&&
            Number.isFinite(c.goods.boards)&&c.goods.boards>=0&&c.required&&
            Number.isInteger(c.required.boards)&&c.required.boards>=0&&
            Number.isFinite(c.progress)&&c.progress>=0&&Number.isFinite(c.duration)&&c.duration>0)||
          !s.builders.every(w=>Number.isFinite(w.x)&&Number.isFinite(w.y)&&Array.isArray(w.path)&&w.path.length<500)))return null;
        if(s.version===3){
          if(!['settlement','legacy'].includes(s.scenario)||!s.staff||typeof s.staff!=='object'||
            !Array.isArray(s.fields)||s.fields.length>W*H||
            !s.fields.every(f=>inside(f.x,f.y)&&['wheat','barley','vegetables'].includes(f.crop)&&
              ['clearing','sown','growing','ripe'].includes(f.stage)&&Number.isFinite(f.progress)&&f.progress>=0))return null;
        }
        if(!Array.isArray(game.workAgents)||game.workAgents.length>W*H||
          !game.workAgents.every(a=>Number.isInteger(a.buildingId)&&Number.isFinite(a.x)&&Number.isFinite(a.y)&&
            ['idle','arrive','out','work','return'].includes(a.phase)&&Number.isFinite(a.progress)&&a.progress>=0&&
            (!a.target||inside(a.target.x,a.target.y))&&
            (!a.carrying||(RES.includes(a.carrying.res)&&Number.isFinite(a.carrying.amount)&&a.carrying.amount>0))))return null;
        game.version=3;
        return game;
      }catch(_){return null;}
    }
  }
  return {Game,W,H,RES,RES_NAME,DEF,COLORS,id,xy};
});
