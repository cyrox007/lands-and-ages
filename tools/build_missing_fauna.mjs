import {writeFileSync,readFileSync,existsSync} from "node:fs";
import {join,dirname} from "node:path";
import {fileURLToPath} from "node:url";
import {buildGlb,verifyModel} from "./build_authored_fauna.mjs";

// Три самостоятельные анатомические модели закрывают отсутствующие виды фауны.
// Каждый результат содержит настоящий Skin и семь скелетных анимаций.
function makeAdditional(species){
  const hare=species==="Hare",hen=species==="Hen",cat=species==="Cat";
  if(!hare&&!hen&&!cat)throw new Error("Неизвестный вид: "+species);
  const bones=[],names={},buckets={};
  const palette=hare?[
    ["Fur",[.58,.4,.25,1]],["Belly",[.87,.78,.62,1]],
    ["EarInside",[.84,.52,.50,1]],["Eyes",[.08,.06,.05,1]],
    ["Nose",[.43,.26,.23,1]]
  ]:hen?[
    ["Feathers",[.55,.32,.18,1]],["Wings",[.37,.2,.12,1]],
    ["BeakFeet",[.89,.63,.21,1]],["Comb",[.63,.1,.11,1]],
    ["Eyes",[.06,.05,.04,1]],["Breast",[.77,.62,.4,1]]
  ]:[
    ["Coat",[.51,.45,.39,1]],["Belly",[.74,.7,.63,1]],
    ["EarInside",[.67,.41,.41,1]],["Eyes",[.78,.68,.3,1]],
    ["Pupil",[.06,.07,.06,1]],["Stripes",[.31,.28,.26,1]]
  ];
  function bone(name,pivot,parent){
    // Позиции костей хранятся глобально, glTF-экспорт сам вычисляет локальные.
    names[name]=bones.length;bones.push({name,pivot,parent});
  }
  bone("Root",[0,0,0],null);
  bone("Body",[0,hen?.51:.44,0],"Root");
  if(hare){
    bone("Head",[0,.56,.48],"Body");
    bone("EarLeft",[.12,.68,.54],"Head");
    bone("EarRight",[-.12,.68,.54],"Head");
    bone("Nose",[0,.49,.71],"Head");
    bone("LegFrontLeft",[.18,.30,.27],"Root");
    bone("LegFrontRight",[-.18,.30,.27],"Root");
    bone("LegBackLeft",[.23,.38,-.32],"Root");
    bone("LegBackRight",[-.23,.38,-.32],"Root");
    bone("Tail",[0,.48,-.55],"Body");
  }else if(hen){
    bone("Neck",[0,.65,.31],"Body");
    bone("Head",[0,.88,.39],"Neck");
    bone("Beak",[0,.83,.56],"Head");
    bone("WingLeft",[.26,.54,-.04],"Body");
    bone("WingRight",[-.26,.54,-.04],"Body");
    bone("LegLeft",[.13,.26,.05],"Root");
    bone("LegRight",[-.13,.26,.05],"Root");
    bone("Tail",[0,.56,-.45],"Body");
  }else{
    bone("Head",[0,.56,.42],"Body");
    bone("EarLeft",[.15,.72,.47],"Head");
    bone("EarRight",[-.15,.72,.47],"Head");
    bone("Nose",[0,.50,.64],"Head");
    bone("LegFrontLeft",[.20,.29,.29],"Root");
    bone("LegFrontRight",[-.20,.29,.29],"Root");
    bone("LegBackLeft",[.20,.29,-.32],"Root");
    bone("LegBackRight",[-.20,.29,-.32],"Root");
    bone("Tail",[0,.47,-.55],"Body");
  }
  const sub=(a,b)=>a.map((v,i)=>v-b[i]);
  const cross=(a,b)=>[a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]];
  const norm=a=>{const size=Math.hypot(...a)||1;return a.map(v=>v/size)};
  function triangle(material,joint,a,b,c){
    // Рёбра и плоские нормали сохраняют узнаваемый силуэт без текстуры.
    if(!buckets[material])buckets[material]=[];
    const raw=cross(sub(b,a),sub(c,a));
    const area=Math.hypot(...raw);
    // В полюсах эллипсоидов есть почти нулевые треугольники:
    // их нормаль должна быть одинаковой в Node/V8 и в CI.
    const n=area<1e-7?[0,1,0]:raw.map(x=>x/area);
    for(const p of [a,b,c])buckets[material].push({p,n,j:names[joint]});
  }
  function ellipsoid(material,joint,center,r,rows=8,cols=12){
    // Части тела отличаются размером и прикрепляются к своей кости.
    const at=(v,u)=>{
      const a=(v/rows-.5)*Math.PI,b=u/cols*2*Math.PI;
      return [center[0]+Math.cos(a)*Math.cos(b)*r[0],
        center[1]+Math.sin(a)*r[1],center[2]+Math.cos(a)*Math.sin(b)*r[2]];
    };
    for(let v=0;v<rows;v++)for(let u=0;u<cols;u++){
      const a=at(v,u),b=at(v+1,u),c=at(v+1,u+1),d=at(v,u+1);
      triangle(material,joint,a,b,c);triangle(material,joint,a,c,d);
    }
  }
  function taper(material,joint,from,to,r0,r1,sides=9){
    // Вытянутые сегменты формируют ноги, уши, клюв и хвосты.
    const axis=norm(sub(to,from)),ref=Math.abs(axis[1])>.8?[1,0,0]:[0,1,0];
    const u=norm(cross(axis,ref)),v=norm(cross(axis,u));
    const at=(p,r,k)=>{
      const t=k*2*Math.PI/sides;
      return p.map((x,i)=>x+r*(u[i]*Math.cos(t)+v[i]*Math.sin(t)));
    };
    for(let k=0;k<sides;k++){
      const a=at(from,r0,k),b=at(from,r0,(k+1)%sides),
        c=at(to,r1,k),d=at(to,r1,(k+1)%sides);
      triangle(material,joint,a,c,b);triangle(material,joint,b,c,d);
      triangle(material,joint,from,b,a);triangle(material,joint,to,c,d);
    }
  }
  function body(material,joint,sections,sides=12){
    // Вытянутые сечения тела не позволяют моделям превратиться в шар.
    const at=(s,k)=>[s[2]*Math.cos(k*2*Math.PI/sides),
      s[1]+s[3]*Math.sin(k*2*Math.PI/sides),s[0]];
    for(let i=0;i<sections.length-1;i++)for(let k=0;k<sides;k++){
      const a=at(sections[i],k),b=at(sections[i+1],k),
        c=at(sections[i+1],(k+1)%sides),d=at(sections[i],(k+1)%sides);
      triangle(material,joint,a,c,b);triangle(material,joint,a,d,c);
    }
  }
  if(hare){
    // У зайца — длинные стоячие уши, объёмные задние лапы и короткий хвост.
    body(0,"Body",[[-.55,.42,.09,.09],[-.37,.45,.25,.25],
      [0,.44,.25,.23],[.29,.43,.19,.18],[.43,.48,.09,.11]],14);
    ellipsoid(1,"Body",[0,.35,.11],[.18,.12,.23]);
    ellipsoid(0,"Head",[0,.60,.49],[.23,.21,.22]);
    for(const sign of [-1,1]){
      const side=sign<0?"Right":"Left",x=sign*.135;
      taper(0,"Ear"+side,[x,.70,.48],[x+sign*.055,1.36,.47],.088,.025,8);
      taper(2,"Ear"+side,[x+sign*.008,.74,.525],[x+sign*.05,1.29,.495],.041,.008,7);
      ellipsoid(3,"Head",[sign*.199,.67,.60],[.031,.042,.035],6,8);
      taper(0,"LegFront"+side,[sign*.175,.34,.31],[sign*.18,.055,.37],.076,.05,8);
      ellipsoid(1,"LegFront"+side,[sign*.18,.055,.42],[.085,.045,.16],6,8);
      ellipsoid(0,"LegBack"+side,[sign*.24,.34,-.31],[.17,.19,.20],7,10);
      taper(0,"LegBack"+side,[sign*.27,.29,-.30],[sign*.26,.05,-.22],.105,.060,8);
      ellipsoid(1,"LegBack"+side,[sign*.26,.05,-.11],[.105,.05,.25],6,8);
    }
    ellipsoid(4,"Nose",[0,.54,.70],[.065,.05,.062],6,8);
    ellipsoid(1,"Tail",[0,.48,-.59],[.15,.15,.15],7,9);
  }else if(hen){
    // У дикой курицы — грудь, короткая шея, два крыла, клюв и хвостовой веер.
    // Длинные петушиные перья больше не используются.
    body(0,"Body",[[-.45,.50,.07,.07],[-.28,.52,.27,.26],
      [.03,.51,.30,.29],[.23,.52,.21,.24],[.39,.58,.09,.10]],14);
    ellipsoid(5,"Body",[0,.43,.19],[.24,.22,.17],7,10);
    taper(0,"Neck",[0,.56,.28],[0,.83,.38],.135,.105,11);
    ellipsoid(0,"Head",[0,.89,.39],[.14,.14,.15],7,10);
    taper(2,"Beak",[0,.845,.51],[0,.81,.76],.10,.012,10);
    for(const sign of [-1,1]){
      const side=sign<0?"Right":"Left",x=sign*.275;
      ellipsoid(1,"Wing"+side,[x,.57,-.04],[.087,.14,.27],7,10);
      ellipsoid(4,"Head",[sign*.13,.92,.48],[.028,.032,.026],6,8);
      taper(2,"Leg"+side,[sign*.13,.29,.05],[sign*.13,.05,.06],.042,.030,8);
      for(let toe=-1;toe<=1;toe++)
        taper(2,"Leg"+side,[sign*.13,.05,.07],[sign*.13+toe*.05,.035,.22],.028,.009,6);
    }
    for(let feather=-2;feather<=2;feather++)
      taper(1,"Tail",[0,.58,-.33],[feather*.085,.92,-.68],.075,.014,7);
    triangle(3,"Head",[-.055,1.02,.36],[0,1.13,.38],[.055,1.02,.36]);
  }else{
    // Кошка — гибкое туловище, четыре лапы, острые уши, узкая мордочка
    // и длинный загнутый вверх хвост. Волчья/лисья модель не подставляется.
    body(0,"Body",[[-.55,.46,.07,.05],[-.37,.47,.23,.18],
      [0,.48,.23,.19],[.27,.47,.21,.18],[.43,.50,.08,.09]],14);
    ellipsoid(1,"Body",[0,.39,.06],[.16,.095,.30],7,10);
    ellipsoid(0,"Head",[0,.60,.43],[.25,.21,.23],8,12);
    for(const sign of [-1,1]){
      const side=sign<0?"Right":"Left";
      triangle(0,"Ear"+side,[sign*.07,.70,.45],[sign*.22,.96,.43],[sign*.27,.71,.44]);
      triangle(2,"Ear"+side,[sign*.115,.73,.49],[sign*.22,.90,.46],[sign*.235,.74,.49]);
      ellipsoid(3,"Head",[sign*.165,.64,.59],[.058,.047,.034],6,8);
      ellipsoid(4,"Head",[sign*.167,.643,.624],[.016,.038,.012],5,7);
      taper(5,"LegFront"+side,[sign*.20,.35,.29],[sign*.20,.06,.32],.080,.047,9);
      ellipsoid(0,"LegFront"+side,[sign*.20,.05,.37],[.069,.05,.11],6,8);
      taper(0,"LegBack"+side,[sign*.20,.36,-.30],[sign*.23,.06,-.29],.099,.048,9);
      ellipsoid(0,"LegBack"+side,[sign*.23,.05,-.22],[.078,.05,.12],6,8);
      for(let i=0;i<3;i++){
        const z=-.36+i*.25;
        taper(5,"Body",[sign*.228,.60,z],[sign*.15,.55,z+.07],.017,.003,6);
      }
    }
    ellipsoid(2,"Nose",[0,.53,.66],[.070,.04,.039],6,9);
    taper(5,"Tail",[0,.49,-.52],[0,.70,-.77],.057,.050,9);
    taper(0,"Tail",[0,.70,-.77],[.11,.99,-.82],.052,.038,9);
    taper(5,"Tail",[.11,.99,-.82],[.20,1.08,-.72],.038,.015,8);
  }
  return {species,bones,names,buckets,palette,extraClips:true};
}

const destination=join(dirname(fileURLToPath(import.meta.url)),"..","godot","assets","fauna");
const check=process.argv.includes("--check");
for(const species of ["Hare","Hen","Cat"]){
  // Детерминированно готовим GLB для игры и обнаруживаем ошибки комплектации.
  const name=species+"_LandsAndAges.glb";
  const path=join(destination,name);
  const bytes=buildGlb(makeAdditional(species)).data;
  if(check){
    if(!existsSync(path))throw new Error("Нет авторской модели: "+name);
    const original=readFileSync(path);
    if(!original.equals(Buffer.from(bytes)))verifyModel(original,bytes);
  }else{writeFileSync(path,Buffer.from(bytes))}
}
