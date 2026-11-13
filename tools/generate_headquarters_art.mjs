// Воспроизводимый генератор отдельных 3D-мешей центра поселения.
// Исходный код хранится вместе с ассетами, все геометрические комментарии на русском.
// Запуск: node tools/generate_headquarters_art.mjs
import { mkdirSync, writeFileSync } from "node:fs";
const generateModels = function generateModels(){
  // Выход — один glTF 2.0 с независимыми 3D-мешами каждого уровня
  // и состояния. В Godot отображается только выбранный дочерний меш.
  const palette={
    "Тёсаный известняк":[.72,.70,.64],
    "Светлая кладка":[.85,.81,.71],
    "Старая кладка":[.46,.45,.42],
    "Штукатурка":[.83,.73,.56],
    "Дубовые балки":[.38,.24,.15],
    "Дубовые наличники":[.56,.35,.19],
    "Красная черепица":[.52,.25,.19],
    "Тёмная черепица":[.36,.17,.15],
    "Ковка":[.19,.22,.24],
    "Тёплое остекление":[.95,.62,.23],
    "Красное полотно":[.62,.15,.13],
    "Золото":[.88,.64,.22],
    "Зелень":[.27,.43,.23],
    "Мох":[.20,.34,.18],
    "Гарь":[.28,.27,.26],
    "Медь":[.57,.37,.24]
  };
  const types=Object.keys(palette),id=n=>types.indexOf(n);
  const materials=types.map(name=>({name,doubleSided:true,pbrMetallicRoughness:{baseColorFactor:[...palette[name],1],metallicFactor:/Ковка|Медь|Золото/.test(name)?.35:0,roughnessFactor:/остекление/.test(name)?.28:.86},...(name==="Тёплое остекление"?{emissiveFactor:[.8,.39,.12]}:{})}));
  const add=(a,b)=>a.map((v,i)=>v+b[i]),sub=(a,b)=>a.map((v,i)=>v-b[i]),cross=(a,b)=>[a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]],scale=(a,s)=>a.map(v=>v*s),unit=a=>{const m=Math.hypot(...a)||1;return a.map(v=>v/m)};
  const all={};
  function make(name){
    const groups=new Map();
    function triangle(a,b,c,kind){
      if(!groups.has(kind))groups.set(kind,{vertices:[],normals:[]});
      const g=groups.get(kind),normal=unit(cross(sub(b,a),sub(c,a)));
      for(const p of [a,b,c]){g.vertices.push(...p);g.normals.push(...normal);}
    }
    const q=(a,b,c,d,m)=>{triangle(a,b,c,m);triangle(a,c,d,m);};
    function block(x,y,z,w,h,d,m,turn=0){
      // Шесть физических граней с нормалями дают настоящую
      // освещаемую геометрию, а не спрайты в плоскости камеры.
      const ca=Math.cos(turn),sa=Math.sin(turn);
      const p=[[-1,-1,-1],[1,-1,-1],[1,1,-1],[-1,1,-1],[-1,-1,1],[1,-1,1],[1,1,1],[-1,1,1]].map(([dx,dy,dz])=>[x+dx*w/2*ca-dz*d/2*sa,y+dy*h/2,z+dx*w/2*sa+dz*d/2*ca]);
      for(const f of [[0,1,2,3],[5,4,7,6],[4,0,3,7],[1,5,6,2],[3,2,6,7],[4,5,1,0]])q(p[f[0]],p[f[1]],p[f[2]],p[f[3]],m);
    }
    function timber(a,b,r,m="Дубовые балки"){
      // Продольные балки и раскосы имеют объёмную ориентацию
      // между опорными точками, сохраняя масштаб при любом угле камеры.
      const axis=unit(sub(b,a)),reference=Math.abs(axis[1])>.95?[1,0,0]:[0,1,0],
            right=unit(cross(axis,reference)),front=unit(cross(right,axis));
      function corners(p){return [[1,1],[-1,1],[-1,-1],[1,-1]].map(([x,z])=>add(add(p,scale(right,x*r)),scale(front,z*r)));}
      const A=corners(a),B=corners(b);
      for(let i=0;i<4;i++){let j=(i+1)%4;q(A[i],A[j],B[j],B[i],m);}
      q(A[0],A[1],A[2],A[3],m);q(B[3],B[2],B[1],B[0],m);
    }
    function cylinder(x,bottom,z,r,h,m,n=10){
      // Бочки и башни из гранёного, но замкнутого объёма.
      const low=[],high=[];
      for(let i=0;i<n;i++){let a=i*Math.PI*2/n;low.push([x+r*Math.cos(a),bottom,z+r*Math.sin(a)]);high.push([x+r*Math.cos(a),bottom+h,z+r*Math.sin(a)]);}
      for(let i=0;i<n;i++){let j=(i+1)%n;q(low[i],low[j],high[j],high[i],m);}
      for(let i=1;i<n-1;i++){triangle(low[0],low[i+1],low[i],m);triangle(high[0],high[i],high[i+1],m);}
    }
    function pointedRoof(x,z,r,y,h){
      // Остроконечные крыши на башнях образованы двенадцатью
      // сегментами и отдельной керамической черепицей по рядам.
      for(let i=0;i<12;i++){
        const a=i*Math.PI/6,b=(i+1)*Math.PI/6;
        let pa=[x+r*Math.cos(a),y,z+r*Math.sin(a)],pb=[x+r*Math.cos(b),y,z+r*Math.sin(b)];
        for(let row=0;row<4;row++){
          let t=row/4,tt=(row+1)/4;
          function lerp(p,k){return [x+(p[0]-x)*(1-k),y+h*k,z+(p[2]-z)*(1-k)];}
          let aa=lerp(pa,t),ab=lerp(pb,t),ba=lerp(pa,tt),bb=lerp(pb,tt);
          q(aa,ab,bb,ba,(i+row)%4===0?"Красная черепица":"Тёмная черепица");
        }
      }
      block(x,y+h+.06,z,.055,.13,.055,"Золото");
    }
    function roof(x,z,w,d,eave,rise,complete=true){
      // Скаты и ряды черепицы следуют настоящему наклону кровли;
      // ряды частично перекрывают друг друга и образуют собственный рельеф.
      for(let side of [-1,1]){
        const ew=w/2+.06,ed=d/2+.05;
        q([x,eave+rise,z-ed],[x+side*ew,eave,z-ed],[x+side*ew,eave,z+ed],[x,eave+rise,z+ed],"Тёмная черепица");
        if(complete)for(let row=0;row<5;row++)for(let j=0;j<8;j++){
          let t=row/5,tn=(row+1.10)/5,ze=z-ed+(j+(row%2)*.4)*2*ed/8,zf=Math.min(z+ed+.02,ze+2*ed/8);
          if(ze>z+ed)continue;
          function pp(k,zz){return [x+side*ew*k,eave+rise*(1-k)+.014,zz];}
          q(pp(t,ze),pp(tn,ze),pp(tn,zf),pp(t,zf),(j+row)%5===0?"Красная черепица":"Тёмная черепица");
        }
        timber([x+side*ew,eave-.012,z-ed],[x+side*ew,eave-.012,z+ed],.018);
      }
      timber([x,eave+rise,z-d/2],[x,eave+rise,z+d/2],.023,"Медь");
    }
    function masonry(w,d,h){
      // Пять рядов штучной каменной облицовки с перевязкой швов:
      // лицевая и боковые стенки сохраняют читаемость в 3D.
      for(let row=0;row<5;row++){
        let yy=.15+(row+.5)*h/5;
        for(let i=0;i<8;i++){
          let x=-w/2+(i+.5+(row%2)*.40)*w/8;
          if(x>w/2-.02)continue;
          block(x,yy,d/2+.016,w/8*.91,h/5*.83,.03,(i+row)%4===0?"Светлая кладка":"Тёсаный известняк");
        }
        for(let i=0;i<8;i++){
          let z=-d/2+(i+.5+(row%2)*.30)*d/8;
          if(z>d/2-.02)continue;
          for(let side of [-1,1])block(side*(w/2+.015),yy,z,.026,h/5*.82,d/8*.91,(i+row)%5===0?"Старая кладка":"Тёсаный известняк");
        }
      }
    }
    function window(x,y,z,side=0){
      // Утопленный светящийся стеклопакет: наличник, тёмная ниша,
      // рамы, подоконник и внутреннее освещение отдельными мешами.
      block(x,y,z,.23,.30,.06,"Светлая кладка",side);
      block(x,y,z+.036,.18,.24,.035,"Ковка",side);
      block(x,y,z+.055,.145,.205,.024,"Тёплое остекление",side);
      block(x,y,z+.071,.023,.24,.019,"Дубовые балки",side);
      block(x,y,z+.073,.18,.020,.021,"Дубовые балки",side);
      block(x,y-.17,z+.085,.27,.05,.13,"Светлая кладка",side);
    }
    function entrance(){
      // Две деревянные створки и каменная арка с клинчатыми
      // сегментами взяты из читаемой композиции исходного концепта.
      block(0,.42,.715,.56,.70,.09,"Гарь");
      for(let side of [-1,1]){
        block(side*.133,.39,.776,.24,.58,.065,"Дубовые балки");
        for(let p=0;p<4;p++)block(side*.133+(p-1.5)*.052,.38,.814,.046,.55,.009,"Дубовые наличники");
        for(let y of [.19,.55])block(side*.133,y,.829,.22,.027,.016,"Ковка");
        block(side*.045,.39,.836,.042,.05,.023,"Золото");
      }
      for(let i=0;i<9;i++){
        let a=Math.PI*i/8,b=Math.PI*(i+1)/8,r=.36,ri=.28,Y=.70,Z=.795;
        q([Math.cos(a)*r,Y+Math.sin(a)*r,Z],[Math.cos(b)*r,Y+Math.sin(b)*r,Z],[Math.cos(b)*ri,Y+Math.sin(b)*ri,Z],[Math.cos(a)*ri,Y+Math.sin(a)*ri,Z],i%3===0?"Светлая кладка":"Тёсаный известняк");
      }
      block(0,.060,.95,.83,.11,.24,"Светлая кладка");
      block(0,.028,1.08,.95,.049,.19,"Тёсаный известняк");
    }
    function lantern(x,z){
      // Фонари — металлические ячейки со светящимся ядром,
      // их размер согласован с архитектурой основного зала.
      block(x,.64,z,.115,.17,.13,"Тёплое остекление");
      for(let dx of [-.063,.063])for(let dz of [-.074,.074])
        timber([x+dx,.54,z+dz],[x+dx,.75,z+dz],.009,"Ковка");
      block(x,.76,z,.15,.04,.17,"Ковка");
    }
    function timberFrame(){
      // Стойки фахверка остаются трёхмерными и подчёркивают
      // разницу деревянной деревенской ратуши от каменной цитадели.
      for(let x of [-.67,.67])for(let z of [-.57,.57])
        timber([x,.23,z],[x,1.12,z],.037);
      for(let z of [-.58,.58]){
        timber([-.7,1.11,z],[.7,1.11,z],.038);
        timber([-.67,.31,z],[.67,1.04,z],.022,"Дубовые наличники");
      }
      for(let x of [-.67,.67])timber([x,1.10,-.59],[x,1.10,.59],.037);
    }
    function platform(){
      // Разгрузочная зона включает отдельные ступени, бочки,
      // деревянные ящики, что связывает внешний вид с рабочим складом.
      entrance();lantern(-.51,.76);lantern(.51,.76);
      block(.80,.16,.50,.22,.26,.23,"Дубовые балки");
      block(.80,.31,.50,.24,.024,.25,"Ковка");
      cylinder(-.82,.05,.48,.13,.26,"Дубовые балки");
      cylinder(-.82,.10,.48,.14,.026,"Ковка");
      cylinder(-.82,.25,.48,.14,.026,"Ковка");
      for(let x of [-.89,.89]){
        block(x,.15,.88,.11,.11,.12,"Зелень");
        block(x,.22,.88,.036,.065,.035,"Золото");
      }
    }
    function turret(x,z,level,broken=false){
      // Круглые/десятигранные башни с каменным цоколем, бойницами,
      // шатровой кровлей и зубцами на четвёртом уровне.
      const r=level===4?.24:.21, height=level===4?1.47:1.17;
      cylinder(x,.24,z,r,height,"Тёсаный известняк");
      cylinder(x,.24,z,r+.04,.15,"Старая кладка");
      for(let j=0;j<10;j++){
        let a=Math.PI*2*j/10;
        block(x+(r+.003)*Math.cos(a),.70,z+(r+.003)*Math.sin(a),.061,.24,.015,j%2?"Светлая кладка":"Ковка",a);
      }
      if(level===4){
        cylinder(x,1.65,z,r+.06,.11,"Старая кладка");
        for(let i=0;i<10;i+=2){
          let a=i*Math.PI/5;
          block(x+(r+.06)*Math.cos(a),1.77,z+(r+.06)*Math.sin(a),.11,.22,.12,"Светлая кладка",a);
        }
      }else if(!broken)pointedRoof(x,z,r+.12,1.40,.42);
    }
    function banner(x,z,y,h){
      // Геральдические красные полотнища сохраняют оригинальную
      // палитру и выделяют общественное здание на фоне жилых домов.
      q([x-.17,y,z],[x+.17,y,z],[x+.17,y+h,z],[x-.17,y+h,z],"Красное полотно");
      block(x,y+h*.52,z+.012,.045,h*.46,.01,"Золото");
      block(x,y+h*.65,z+.013,.18,.035,.012,"Золото");
      timber([x-.19,y+h+.01,z],[x+.19,y+h+.01,z],.015);
    }
    function base(){
      // Общая геометрическая основа занимает не более 2×2 клеток,
      // чтобы существующие правила физики и коллизии совпадали с арт-пакетом.
      block(0,.07,0,1.91,.14,1.91,"Старая кладка");
      block(0,.19,0,1.54,.21,1.42,"Тёсаный известняк");
      masonry(1.54,1.42,.24);
    }
    function walls(level,broken=false){
      // Штукатурка и деревянный каркас первых ступеней сменяются
      // каменным вторым этажом и крепостной кладкой.
      let tall=level>=3?1.11:.85;
      block(0,.30+tall/2,0,1.39,tall,1.20,level>=3?"Тёсаный известняк":"Штукатурка");
      timberFrame();
      for(let x of [-.41,.41])window(x,.70,.618);
      window(0,.72,-.62);
      if(level>=2)for(let side of [-1,1]){
        block(side*.70,.48,-.08,.50,.68,.85,"Тёсаный известняк");
        window(side*.70,.64,.365);
        roof(side*.70,-.08,.52,.91,.84,.25,!broken);
      }
      if(level>=3){
        block(0,1.33,-.08,.82,.49,.78,"Светлая кладка");
        window(0,1.31,.332);
      }
      if(!broken)roof(0,-.04,1.42,1.28,level>=3?1.38:1.17,.46,true);
    }
    function complete(level,broken=false){
      // Последовательная архитектура: фахверковая ратуша, каменная
      // управа, укреплённый центр, крепость с центральным донжоном.
      base();walls(level,broken);platform();
      if(level===1){
        cylinder(0,1.20,-.21,.26,.45,"Дубовые наличники");
        for(let i=0;i<4;i++){
          let a=i*Math.PI/2;
          block(.26*Math.cos(a),1.40,-.21+.26*Math.sin(a),.14,.18,.025,"Тёплое остекление",a);
        }
        if(!broken)pointedRoof(0,-.21,.35,1.63,.48);
        timber([0,2.08,-.21],[0,2.47,-.21],.015,"Медь");
        banner(.15,-.21,2.20,.22);
      }
      if(level===2){
        turret(.04,-.19,level,broken);
        timber([-.80,1.0,.26],[-.80,1.70,.26],.016,"Медь");
        banner(-.60,.26,1.32,.32);
      }
      if(level>=3){
        for(let x of [-.77,.77])turret(x,.70,level,broken);
        block(0,.66,-.78,1.26,.64,.17,"Старая кладка");
        for(let i=0;i<7;i++)if(!broken||i!==3)
          block(-.56+i*.18,1.05,-.78,.12,.21,.22,"Светлая кладка");
      }
      if(level===4){
        for(let x of [-.77,.77])turret(x,-.75,level,broken);
        block(0,1.59,-.12,.63,.96,.67,"Светлая кладка");
        if(!broken)pointedRoof(0,-.12,.47,2.11,.54);
        for(let x of [-.15,.15])window(x,1.63,.237);
        for(let x of [-.7,.7]){
          timber([x,1.86,.65],[x,2.47,.65],.016,"Медь");
          banner(x+.15,.65,2.19,.26);
        }
      }
      if(broken){
        // Тяжёлые разрушения убирают цельную крышу и добавляют
        // обрушенные стропила и разбросанные камни.
        for(let i=0;i<7;i++){
          const x=-.68+i*.23;
          timber([x,.73,-.54],[x+.17,1.05,.18],.027,i%2?"Гарь":"Дубовые балки");
          block(x,.12,.77,.20,.13,.18,"Старая кладка",i*.25);
        }
      }
    }
    function construction(stage){
      // Стройка отображает реальную последовательность: нижний ряд,
      // несущий каркас, стены, крыша; оконченный центр — другой меш.
      base();
      if(stage>=1)timberFrame();
      if(stage>=2){
        block(0,.73,0,1.38,.85,1.2,"Штукатурка");
        for(let x of [-.42,.42])window(x,.69,.62);
      }
      if(stage>=3)roof(0,-.04,1.44,1.29,1.17,.46,true);
      if(stage>=1)scaffold();
    }
    function scaffold(){
      // Съёмные леса — отдельный меш, который Godot добавляет лишь
      // при физическом незавершённом строительстве.
      for(let x of [-.94,.94])for(let z of [-.87,.87])
        timber([x,.08,z],[x,1.40,z],.022,"Дубовые наличники");
      for(let h of [.5,1.05]){
        for(let x of [-.94,.94])timber([x,h,-.90],[x,h,.90],.016);
        for(let z of [-.87,.87])timber([-.94,h,z],[.94,h,z],.016);
      }
      block(0,1.08,.90,1.84,.05,.12,"Дубовые балки");
    }
    function ruins(age){
      // Физические руины — разобранные стены и балки. Возраст
      // управляет числом травяных и моховых пучков, а не альфой картинки.
      base();
      for(let i=0;i<28;i++){
        const a=i*2.39996,rad=.15+.70*((i*31)%17)/17;
        let x=Math.cos(a)*rad,z=Math.sin(a)*rad;
        block(x,.20,z,.12+.04*(i%3),.13+.05*(i%4),.16+.02*(i%2),age>=1&&i%3===0?"Гарь":"Старая кладка",a);
      }
      for(let i=0;i<6;i++)timber([-.65+i*.23,.23,.28],[-.48+i*.23,.30,-.38],.027,age>=1?"Гарь":"Дубовые балки");
      if(age>=1)for(let i=0;i<10;i++)
        block(-.78+(i%5)*.36,.25,-.58+Math.floor(i/5)*1.12,.13,.05,.12,"Мох");
      if(age>=2)for(let i=0;i<16;i++){
        let a=i*1.9,r=.30+.56*((i*17)%13)/13;
        block(Math.cos(a)*r,.27,Math.sin(a)*r,.13,.24,.10,i%4?"Зелень":"Мох",a);
      }
    }
    function cracks(){
      // Трещины и сколотые плиты — отдельный пространственный
      // декор малых повреждений, без подмены целой конструкции.
      for(let i=0;i<14;i++){
        let x=-.69+(i%7)*.23,y=.29+Math.floor(i/7)*.29;
        timber([x,y,.70],[x+.045,y-.10,.72],.007,"Гарь");
      }
      for(let i=0;i<5;i++)block(-.68+(i%3)*.55,.09,.84,.17,.13,.15,"Старая кладка",i*.38);
    }
    const work={
      "Level_1":()=>complete(1),"Level_2":()=>complete(2),
      "Level_3":()=>complete(3),"Level_4":()=>complete(4),
      "Level_1_Broken":()=>complete(1,true),"Level_2_Broken":()=>complete(2,true),
      "Level_3_Broken":()=>complete(3,true),"Level_4_Broken":()=>complete(4,true),
      "Foundation":()=>construction(0),"Frame":()=>construction(1),
      "Walls":()=>construction(2),"Roof":()=>construction(3),
      "Ruins_Fresh":()=>ruins(0),"Ruins_Old":()=>ruins(1),
      "Ruins_Overgrown":()=>ruins(2),
      "Damage_Marks":()=>cracks(),"Scaffolding":()=>scaffold()
    };
    if(!work[name])throw Error("Нет модели: "+name);
    work[name]();
    all[name]=groups;
  }
  for(const name of [
    "Level_1","Level_2","Level_3","Level_4",
    "Level_1_Broken","Level_2_Broken","Level_3_Broken","Level_4_Broken",
    "Foundation","Frame","Walls","Roof","Ruins_Fresh","Ruins_Old",
    "Ruins_Overgrown","Damage_Marks","Scaffolding"])make(name);

  // Упаковываем все вершины и нормали в один самодостаточный буфер:
  // Godot импортирует glTF как сцену с именованными мешами.
  const buffers=[],views=[],accessors=[],meshes=[],nodes=[],stats={};
  function typed(values,position){
    let off=buffers.length;
    const ab=new ArrayBuffer(values.length*4),dv=new DataView(ab);
    for(let i=0;i<values.length;i++)dv.setFloat32(i*4,values[i],true);
    buffers.push(...new Uint8Array(ab));
    const v=views.length;views.push({buffer:0,byteOffset:off,byteLength:ab.byteLength,target:34962});
    const acc={bufferView:v,componentType:5126,count:values.length/3,type:"VEC3"};
    if(position){
      const mn=[Infinity,Infinity,Infinity],mx=[-Infinity,-Infinity,-Infinity];
      for(let i=0;i<values.length;i+=3)for(let k=0;k<3;k++){mn[k]=Math.min(mn[k],values[i+k]);mx[k]=Math.max(mx[k],values[i+k]);}
      acc.min=mn;acc.max=mx;
    }
    accessors.push(acc);
    return accessors.length-1;
  }
  for(const [name,groups] of Object.entries(all)){
    const primitives=[];let triangles=0;
    for(const [kind,g] of groups.entries()){
      if(!g.vertices.length)continue;
      const pos=typed(g.vertices,true),normal=typed(g.normals,false);
      primitives.push({attributes:{POSITION:pos,NORMAL:normal},material:id(kind),mode:4});
      triangles+=g.vertices.length/9;
    }
    meshes.push({name,primitives});
    nodes.push({name,mesh:meshes.length-1});
    stats[name]=triangles;
  }
  // Base64 встроен в glTF: никаких внешних бинарных .bin или PNG.
  const alphabet="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  let b64="";
  for(let i=0;i<buffers.length;i+=3){
    let a=buffers[i],b=i+1<buffers.length?buffers[i+1]:0,c=i+2<buffers.length?buffers[i+2]:0;
    let value=(a<<16)|(b<<8)|c;
    b64+=alphabet[(value>>>18)&63]+alphabet[(value>>>12)&63]+(i+1<buffers.length?alphabet[(value>>>6)&63]:"=")+(i+2<buffers.length?alphabet[value&63]:"=");
  }
  const gltf={asset:{version:"2.0",generator:"Lands and Ages — художественный 3D-комплект 13.6"},scene:0,scenes:[{nodes:nodes.map((_,i)=>i)}],nodes,meshes,materials,buffers:[{byteLength:buffers.length,uri:"data:application/octet-stream;base64,"+b64}],bufferViews:views,accessors};
  return {content:JSON.stringify(gltf),stats,meshes:meshes.length,triangles:Object.values(stats).reduce((a,b)=>a+b,0)};
};
const output = generateModels();
mkdirSync("godot/assets/buildings/headquarters", { recursive: true });
writeFileSync("godot/assets/buildings/headquarters/headquarters_art.gltf", output.content);
writeFileSync("godot/assets/buildings/headquarters/geometry_manifest.json", JSON.stringify({ meshes:output.stats, triangles:output.triangles}, null, 2)+"\\n");
