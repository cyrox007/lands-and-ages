import {writeFileSync,readFileSync,existsSync} from "node:fs";
import {join,dirname} from "node:path";
import {fileURLToPath} from "node:url";

// Авторские анатомические сетки. Пересоздание файлов не требует интернета.
function makeAnimal(species) {
  // Создаём оригинальную анатомическую сетку животного и отдельный набор костей.
  // Экспортируем не геометрические заглушки, а полную skinned-модель с клипами.
  const goose = species === "Goose";
  const bones=[],names={},buckets={};
  const palette=goose?[
    ["Feathers",[.89,.9,.88,1]],["Wings",[.76,.8,.79,1]],
    ["BeakAndFeet",[.92,.44,.12,1]],["Eyes",[.04,.035,.032,1]],
    ["NeckHighlight",[.97,.96,.9,1]]
  ]:[
    ["Coat",[.43,.25,.18,1]],["Mane",[.28,.16,.12,1]],
    ["Snout",[.59,.36,.27,1]],["NoseAndHooves",[.14,.12,.12,1]],
    ["Tusks",[.95,.9,.7,1]],["Eyes",[.035,.028,.024,1]]
  ];
  function bone(name,pivot,parent){names[name]=bones.length;bones.push({name,pivot,parent});}
  bone("Root",[0,0,0],null);bone("Body",[0,goose?.52:.63,0],"Root");
  if(goose){
    bone("Neck",[0,.7,.32],"Body");bone("Head",[0,1.21,.52],"Neck");
    bone("Beak",[0,1.19,.68],"Head");
    bone("WingLeft",[.29,.6,-.08],"Body");bone("WingRight",[-.29,.6,-.08],"Body");
    bone("LegLeft",[.14,.32,-.09],"Root");bone("LegRight",[-.14,.32,-.09],"Root");
    bone("Tail",[0,.6,-.48],"Body");
  }else{
    bone("Head",[0,.67,.66],"Body");bone("Snout",[0,.55,1.04],"Head");
    bone("EarLeft",[.24,.87,.56],"Head");bone("EarRight",[-.24,.87,.56],"Head");
    bone("TuskLeft",[.2,.55,1.02],"Head");bone("TuskRight",[-.2,.55,1.02],"Head");
    bone("LegFrontLeft",[.28,.40,.40],"Root");bone("LegFrontRight",[-.28,.40,.40],"Root");
    bone("LegBackLeft",[.29,.41,-.48],"Root");bone("LegBackRight",[-.29,.41,-.48],"Root");
    bone("Tail",[0,.7,-.73],"Body");
  }
  function cross(a,b){return [a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]];}
  function sub(a,b){return [a[0]-b[0],a[1]-b[1],a[2]-b[2]];}
  function norm(a){const d=Math.hypot(...a)||1;return a.map(x=>x/d);}
  function tri(mat,joint,a,b,c){
    // Фасеточные нормали делают сечение читаемым даже при небольшом масштабе камеры.
    if(!buckets[mat])buckets[mat]=[];
    const normal=norm(cross(sub(b,a),sub(c,a)));
    for(const p of [a,b,c])buckets[mat].push({p,n:normal,j:names[joint]});
  }
  function ellipsoid(mat,joint,center,r,lat=9,lon=12){
    // Детали головы, крыльев, глаз и копыт имеют независимые материалы.
    const at=(v,u)=>{const a=(v/lat-.5)*Math.PI,b=u/lon*2*Math.PI;
      return [center[0]+Math.cos(a)*Math.cos(b)*r[0],center[1]+Math.sin(a)*r[1],center[2]+Math.cos(a)*Math.sin(b)*r[2]];};
    for(let v=0;v<lat;v++)for(let u=0;u<lon;u++){
      const a=at(v,u),b=at(v+1,u),c=at(v+1,u+1),d=at(v,u+1);
      tri(mat,joint,a,b,c);tri(mat,joint,a,c,d);
    }
  }
  function loft(mat,joint,sections,sides=14){
    // Туловище строим по нескольким разным сечениям, а не из шара.
    const at=(s,k)=>[Math.cos(k*2*Math.PI/sides)*s[2],s[1]+Math.sin(k*2*Math.PI/sides)*s[3],s[0]];
    for(let i=0;i<sections.length-1;i++)for(let k=0;k<sides;k++){
      const a=at(sections[i],k),b=at(sections[i+1],k),c=at(sections[i+1],(k+1)%sides),d=at(sections[i],(k+1)%sides);
      tri(mat,joint,a,c,b);tri(mat,joint,a,d,c);
    }
    for(let k=0;k<sides;k++){
      const lo=sections[0],hi=sections[sections.length-1];
      tri(mat,joint,[0,lo[1],lo[0]],at(lo,k),at(lo,(k+1)%sides));
      tri(mat,joint,[0,hi[1],hi[0]],at(hi,(k+1)%sides),at(hi,k));
    }
  }
  function tapered(mat,joint,from,to,r0,r1,sides=10){
    // Соединяем поперечные кольца вдоль оси сегмента, формируя ноги, шею, клюв, клыки.
    const axis=norm(sub(to,from)),ref=Math.abs(axis[1])>.8?[1,0,0]:[0,1,0];
    const u=norm(cross(axis,ref)),v=norm(cross(axis,u));
    const at=(p,r,k)=>{const t=k*2*Math.PI/sides;
      return [0,1,2].map(i=>p[i]+r*(Math.cos(t)*u[i]+Math.sin(t)*v[i]));};
    for(let k=0;k<sides;k++){
      const a=at(from,r0,k),b=at(from,r0,(k+1)%sides),c=at(to,r1,k),d=at(to,r1,(k+1)%sides);
      tri(mat,joint,a,c,b);tri(mat,joint,b,c,d);
      tri(mat,joint,from,b,a);tri(mat,joint,to,c,d);
    }
  }
  if(goose){
    // У гуся длинная изогнутая шея с головой над корпусом, клюв и две перепончатые лапы.
    loft(0,"Body",[[-.55,.52,.035,.05],[-.42,.53,.27,.18],[-.20,.55,.35,.255],[.09,.55,.33,.24],[.31,.55,.25,.21],[.43,.57,.13,.14]],16);
    for(const [name,x] of [["WingLeft",.295],["WingRight",-.295]]){
      ellipsoid(1,name,[x,.61,-.11],[.095,.12,.325],7,10);
      for(let k=0;k<3;k++)tapered(1,name,[x*.96,.63,-.25-k*.065],[x*.91,.55,-.46-k*.045],.055,.009,7);
    }
    tapered(0,"Neck",[0,.61,.29],[0,.83,.38],.148,.12,12);
    tapered(4,"Neck",[0,.80,.36],[0,1.10,.46],.12,.09,12);
    tapered(4,"Neck",[0,1.07,.44],[0,1.20,.53],.095,.11,10);
    ellipsoid(4,"Head",[0,1.22,.54],[.145,.145,.17],9,12);
    tapered(2,"Beak",[0,1.19,.68],[0,1.15,.96],.115,.035,10);
    for(const sign of [-1,1]){
      ellipsoid(3,"Head",[sign*.135,1.265,.605],[.032,.038,.032],6,8);
      const leg=sign<0?"LegRight":"LegLeft",x=sign*.155;
      tapered(2,leg,[x,.38,-.12],[x,.08,-.07],.037,.033,9);
      tapered(2,leg,[x,.08,-.07],[x,.055,.22],.06,.048,9);
      for(let k=-1;k<=1;k++)tapered(2,leg,[x,.055,.2],[x+k*.073,.042,.32],.035,.01,6);
    }
    tri(0,"Tail",[-.18,.63,-.50],[0,.63,-.77],[.18,.63,-.50]);
    tri(1,"Tail",[-.13,.58,-.52],[0,.70,-.75],[.13,.58,-.52]);
  }else{
    // У кабана четыре ноги, вытянутая морда, широкое рыло и отдельные клыки.
    loft(0,"Body",[[-.78,.61,.045,.05],[-.58,.65,.31,.27],[-.27,.68,.395,.34],[.15,.69,.40,.34],[.46,.68,.32,.27],[.66,.66,.18,.19]],16);
    ellipsoid(0,"Head",[0,.66,.66],[.30,.25,.32],9,12);
    tapered(2,"Snout",[0,.57,.79],[0,.55,1.25],.20,.155,12);
    ellipsoid(3,"Snout",[0,.55,1.25],[.162,.11,.07],7,12);
    for(const sign of [-1,1]){
      const side=sign<0?"Right":"Left",x=sign*.255;
      ellipsoid(5,"Head",[sign*.277,.755,.875],[.035,.042,.03],6,8);
      tri(1,"Ear"+side,[x,.81,.52],[sign*.36,1.08,.57],[sign*.12,.90,.60]);
      tri(2,"Ear"+side,[x,.84,.535],[sign*.32,1.035,.565],[sign*.16,.90,.58]);
      tapered(4,"Tusk"+side,[sign*.19,.50,1.02],[sign*.25,.77,1.14],.078,.009,8);
    }
    for(const [name,x,z] of [["LegFrontLeft",.285,.43],["LegFrontRight",-.285,.43],["LegBackLeft",.29,-.50],["LegBackRight",-.29,-.50]]){
      tapered(0,name,[x,.48,z],[x*1.06,.08,z+.02],.117,.069,9);
      ellipsoid(3,name,[x*1.06,.072,z+.045],[.091,.065,.13],6,9);
    }
    // Щетина и хвост устраняют прежний округлый силуэт.
    for(let k=0;k<11;k++){const z=-.45+k*.105,y=.95+(k<5?.035:.01),h=(k%3)*.035;
      tri(1,"Body",[-.065,y,z],[0,y+.10+h,z-.045],[.065,y,z]);}
    tapered(1,"Tail",[0,.69,-.73],[0,.72,-.91],.045,.023,8);
    tapered(1,"Tail",[0,.72,-.91],[.055,.79,-.99],.025,.009,8);
  }
  return {species,bones,names,buckets,palette};
}

function buildGlb(model){
  // Пишем стандартный GLB 2.0: вершины, нормали, веса костей,
  // обратные матрицы покоя и четыре самостоятельных анимационных клипа.
  const bytes=[],accessors=[],bufferViews=[];
  const align=()=>{while(bytes.length%4)bytes.push(0)};
  function view(values,componentType,count,type,min,max){
    align();const off=bytes.length,sz=componentType===5126?4:2,dv=new DataView(new ArrayBuffer(sz));
    for(const v of values){
      if(componentType===5126)dv.setFloat32(0,v,true);else dv.setUint16(0,v,true);
      for(let i=0;i<sz;i++)bytes.push(dv.getUint8(i));
    }
    const bi=bufferViews.push({buffer:0,byteOffset:off,byteLength:bytes.length-off})-1;
    const entry={bufferView:bi,componentType,count,type};
    if(min)entry.min=min;if(max)entry.max=max;
    return accessors.push(entry)-1;
  }
  const bones=model.bones,names=model.names,joints=bones.map((_,i)=>i+3);
  const inv=[];
  for(const b of bones){
    const p=b.pivot;inv.push(1,0,0,0,0,1,0,0,0,0,1,0,-p[0],-p[1],-p[2],1);
  }
  const ibm=view(inv,5126,bones.length,"MAT4");
  const materials=model.palette.map(([name,color])=>({
    name,pbrMetallicRoughness:{baseColorFactor:color,metallicFactor:0,roughnessFactor:.88},doubleSided:true
  }));
  const primitives=[];
  for(const key of Object.keys(model.buckets)){
    const verts=model.buckets[key],pos=[],normal=[],joint=[],weight=[],inds=[];
    for(let i=0;i<verts.length;i++){
      const v=verts[i];pos.push(...v.p);normal.push(...v.n);
      joint.push(v.j,0,0,0);weight.push(1,0,0,0);inds.push(i);
    }
    const min=[0,1,2].map(k=>Math.min(...verts.map(v=>v.p[k])));
    const max=[0,1,2].map(k=>Math.max(...verts.map(v=>v.p[k])));
    const p=view(pos,5126,verts.length,"VEC3",min,max);
    const n=view(normal,5126,verts.length,"VEC3");
    const j=view(joint,5123,verts.length,"VEC4");
    const w=view(weight,5126,verts.length,"VEC4");
    const indices=view(inds,5123,inds.length,"SCALAR");
    primitives.push({attributes:{POSITION:p,NORMAL:n,JOINTS_0:j,WEIGHTS_0:w},indices,material:Number(key),mode:4});
  }
  const nodes=[
    {name:model.species+"Model",children:[1,2]},
    {name:model.species+"Skinned",mesh:0,skin:0},
    {name:"Armature",children:[]}
  ];
  for(const b of bones){
    const par=b.parent?bones[names[b.parent]]:null;
    nodes.push({name:b.name,translation:par?b.pivot.map((v,k)=>v-par.pivot[k]):b.pivot});
  }
  for(let i=0;i<bones.length;i++){
    const par=bones[i].parent;
    const idx=par?joints[names[par]]:2;
    if(!nodes[idx].children)nodes[idx].children=[];
    nodes[idx].children.push(joints[i]);
  }
  const animations=[];
  const times=[0,.25,.5,.75,1];
  const quat=(axis,a)=>{const s=Math.sin(a/2),c=Math.cos(a/2);return axis==="x"?[s,0,0,c]:axis==="y"?[0,s,0,c]:[0,0,s,c];};
  for(const clip of (model.extraClips ? ["Idle","Walk","Run","Eating","Alert","Attack","Death"] : ["Idle","Walk","Attack","Death"])){
    const channels=[],samplers=[],input=view(times,5126,times.length,"SCALAR",[0],[1]);
    for(const b of bones){
      const action={
        Root:["z",clip==="Death"?.95:0],
        Body:["z",clip==="Idle"?.018:clip==="Walk"?.065:clip==="Run"?.10:0],
        Head:["x",clip==="Attack"?.21:clip==="Eating"?.23:clip==="Alert"?.10:.032],
        Neck:["x",clip==="Attack"?.20:.035],
        WingLeft:["z",clip==="Walk"?.12:.027],
        WingRight:["z",clip==="Walk"?-.12:-.027],
        LegLeft:["x",clip==="Run"?.55:clip==="Walk"?.35:.018],
        LegRight:["x",clip==="Run"?-.55:clip==="Walk"?-.35:-.018],
        LegFrontLeft:["x",clip==="Run"?.55:clip==="Walk"?.36:.02],
        LegFrontRight:["x",clip==="Run"?-.55:clip==="Walk"?-.36:-.02],
        LegBackLeft:["x",clip==="Run"?-.55:clip==="Walk"?-.36:.02],
        LegBackRight:["x",clip==="Run"?.55:clip==="Walk"?.36:-.02],
        Snout:["x",clip==="Attack"?.17:.01],Tail:["y",clip==="Walk"?.13:.04]
      }[b.name];
      if(!action)continue;
      const [axis,amp]=action,out=[];
      for(let i=0;i<times.length;i++){
        const angle=clip==="Death"?amp*i/4:amp*Math.sin(times[i]*Math.PI*2+(b.name.includes("Right")?Math.PI:0));
        out.push(...quat(axis,angle));
      }
      const output=view(out,5126,times.length,"VEC4");
      const sampler=samplers.push({input,output,interpolation:"LINEAR"})-1;
      channels.push({sampler,target:{node:joints[names[b.name]],path:"rotation"}});
    }
    animations.push({name:clip,samplers,channels});
  }
  const gltf={
    asset:{version:"2.0",generator:"Lands and Ages: original low-poly fauna",copyright:"Lands and Ages - original project-owned models"},
    scene:0,scenes:[{nodes:[0]}],nodes,meshes:[{name:model.species+"AnimatedMesh",primitives}],
    skins:[{name:model.species+"Skeleton",joints,skeleton:2,inverseBindMatrices:ibm}],
    animations,materials,buffers:[{byteLength:bytes.length}],bufferViews,accessors
  };
  const json=JSON.stringify(gltf),txt=[];
  // ASCII в метаданных позволяет точно воспроизводить бинарный glTF без сторонних библиотек.
  for(let i=0;i<json.length;i++)txt.push(json.charCodeAt(i));
  while(txt.length%4)txt.push(32);
  align();const len=12+8+txt.length+8+bytes.length;
  const data=new Uint8Array(len),dv=new DataView(data.buffer);
  function put(offset,num){dv.setUint32(offset,num,true);}
  put(0,0x46546c67);put(4,2);put(8,len);put(12,txt.length);put(16,0x4e4f534a);
  data.set(txt,20);const off=20+txt.length;
  put(off,bytes.length);put(off+4,0x004e4942);data.set(bytes,off+8);
  return {data,gltf};
}


// Сравниваем повторную генерацию с утверждённым GLB по его геометрии.
// Тригонометрия движков Node/V8 может различаться на несколько бит float32,
// поэтому побайтовое совпадение не является корректным инвариантом модели.
function unpackGlb(data){
  // Оба файла имеют два чанка: документ JSON и бинарный буфер вершин.
  const bytes=Buffer.from(data);
  const jsonLength=bytes.readUInt32LE(12);
  const doc=JSON.parse(bytes.subarray(20,20+jsonLength).toString("utf8"));
  const binAt=20+jsonLength+8;
  return {doc,buffer:bytes.subarray(binAt)};
}
function compareStruct(a,b,path="root"){
  // Сохраняем строгую структуру костей, рига, материалов и анимаций.
  // Допускаем только погрешность округления конечных чисел.
  if(typeof a==="number"&&typeof b==="number"){
    if(!Number.isFinite(a)||!Number.isFinite(b)||Math.abs(a-b)>0.00001){
      throw new Error("Различие геометрического числа: "+path);
    }
    return;
  }
  if(Array.isArray(a)||Array.isArray(b)){
    if(!Array.isArray(a)||!Array.isArray(b)||a.length!==b.length){
      throw new Error("Изменена структура массива: "+path);
    }
    for(let i=0;i<a.length;i++)compareStruct(a[i],b[i],path+"["+i+"]");
    return;
  }
  if(a!==null&&b!==null&&typeof a==="object"&&typeof b==="object"){
    const ak=Object.keys(a).sort(),bk=Object.keys(b).sort();
    if(ak.join("|")!==bk.join("|"))throw new Error("Изменены поля: "+path);
    for(const k of ak)compareStruct(a[k],b[k],path+"."+k);
    return;
  }
  if(a!==b)throw new Error("Изменён элемент модели: "+path);
}
function verifyModel(known,recreated){
  // Проверяем не только JSON, но и каждую вершину, вес, сустав и индекс.
  const a=unpackGlb(known),b=unpackGlb(recreated);
  compareStruct(a.doc,b.doc);
  const components={SCALAR:1,VEC2:2,VEC3:3,VEC4:4,MAT4:16};
  for(let i=0;i<a.doc.accessors.length;i++){
    const left=a.doc.accessors[i],right=b.doc.accessors[i];
    const la=a.doc.bufferViews[left.bufferView],rb=b.doc.bufferViews[right.bufferView];
    const offA=la.byteOffset||0,offB=rb.byteOffset||0;
    const total=left.count*components[left.type];
    const f=left.componentType===5126;
    if(!f&&left.componentType!==5123)throw new Error("Неизвестный формат вершин");
    for(let j=0;j<total;j++){
      const x=f?a.buffer.readFloatLE(offA+j*4):a.buffer.readUInt16LE(offA+j*2);
      const y=f?b.buffer.readFloatLE(offB+j*4):b.buffer.readUInt16LE(offB+j*2);
      if(!Number.isFinite(x)||!Number.isFinite(y)||Math.abs(x-y)>(f?0.00001:0)){
        throw new Error("Изменён бинарный элемент "+i+":"+j);
      }
    }
  }
}

const destination=join(dirname(fileURLToPath(import.meta.url)),"..","godot","assets","fauna");
const check=process.argv.includes("--check");
if (process.argv[1] && process.argv[1].endsWith("build_authored_fauna.mjs")) {
  // При прямом запуске проверяем только два исходных авторских вида.
  // Импорт модуля не должен тайно менять файлы проекта.
  for(const species of ["Goose","Boar"]){
    const output=join(destination,species+"_LandsAndAges.glb");
    const data=buildGlb(makeAnimal(species)).data;
    if(check){
      if(!existsSync(output))throw new Error("Отсутствует авторская модель: "+output);
      const old=readFileSync(output);
      if(!old.equals(Buffer.from(data)))verifyModel(old,data);
    }else{writeFileSync(output,Buffer.from(data))}
  }
}
export {buildGlb,verifyModel};
